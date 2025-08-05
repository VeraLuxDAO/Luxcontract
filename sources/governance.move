module veralux::governance {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::vector;
    use veralux::multisig::{Self, MultisigConfig};
    use veralux::staking::{Self, StakePool, StakePosition};
    use veralux::token_management::{Self, TOKEN_MANAGEMENT, TokenConfig};
    use veralux::treasury::{Self, TreasuryConfig};

    const VOTING_PERIOD: u64 = 1_209_600_000; // 14 days in milliseconds
    const EXECUTION_DELAY: u64 = 259_200_000; // 3 days in milliseconds
    const QUORUM_PERCENTAGE: u64 = 40; // 40%
    const APPROVAL_PERCENTAGE: u64 = 60; // 60%
    const MIN_YES_VP_PERCENTAGE: u64 = 25; // 25%

    const E_UNAUTHORIZED: u64 = 0;
    const E_PROPOSAL_NOT_FOUND: u64 = 1;
    const E_ALREADY_VOTED: u64 = 2;
    const E_VOTING_PERIOD_ENDED: u64 = 3;
    const E_PROPOSAL_NOT_APPROVED: u64 = 4;
    const E_EXECUTION_DELAY_NOT_PASSED: u64 = 5;

    public struct GovernanceConfig has key, store {
        id: UID,
        proposals: Table<u64, Proposal>,
        next_proposal_id: u64,
    }

    public struct Proposal has store {
        id: u64,
        type: u8,
        parameters: vector<u8>,
        start_time: u64,
        end_time: u64,
        total_vp_yes: u64,
        total_vp_no: u64,
        voters: Table<address, bool>,
        status: u8, // 0: pending, 1: approved, 2: rejected
    }

    fun init(ctx: &mut TxContext) {
        let config = GovernanceConfig {
            id: object::new(ctx),
            proposals: table::new(ctx),
            next_proposal_id: 0,
        };
        transfer::share_object(config);
    }

    public entry fun submit_proposal(
        governance: &mut GovernanceConfig,
        multisig: &MultisigConfig,
        action_id: u64,
        proposal_type: u8,
        parameters: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(multisig::is_action_ready(multisig, action_id, clock), E_UNAUTHORIZED);
        let (action_type, _, _) = multisig::get_action_details(multisig, action_id);
        assert!(action_type == b"submit_proposal", E_UNAUTHORIZED);

        let current_time = clock::timestamp_ms(clock);
        let proposal_id = governance.next_proposal_id;
        governance.next_proposal_id = proposal_id + 1;
        let proposal = Proposal {
            id: proposal_id,
            type: proposal_type,
            parameters,
            start_time: current_time,
            end_time: current_time + VOTING_PERIOD,
            total_vp_yes: 0,
            total_vp_no: 0,
            voters: table::new(ctx),
            status: 0,
        };
        table::add(&mut governance.proposals, proposal_id, proposal);
        multisig::remove_action(multisig, action_id);
    }

    public entry fun vote(
        governance: &mut GovernanceConfig,
        staking_pool: &StakePool,
        proposal_id: u64,
        vote_yes: bool,
        position: &StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&governance.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = table::borrow_mut(&mut governance.proposals, proposal_id);
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time < proposal.end_time, E_VOTING_PERIOD_ENDED);
        assert!(!table::contains(&proposal.voters, sender), E_ALREADY_VOTED);

        assert!(staking::get_stake_position_id(staking_pool, sender) == object::id(position), E_UNAUTHORIZED);

        let total_vp = staking::get_total_vp(staking_pool);
        let capped_vp = if (position.vp > total_vp / 50) total_vp / 50 else position.vp;

        if (vote_yes) {
            proposal.total_vp_yes = proposal.total_vp_yes + capped_vp;
        } else {
            proposal.total_vp_no = proposal.total_vp_no + capped_vp;
        };
        table::add(&mut proposal.voters, sender, vote_yes);
    }

    public entry fun finalize_proposal(
        governance: &mut GovernanceConfig,
        staking_pool: &StakePool,
        proposal_id: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&governance.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = table::borrow_mut(&mut governance.proposals, proposal_id);
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= proposal.end_time, E_VOTING_PERIOD_ENDED);
        assert!(proposal.status == 0, E_PROPOSAL_NOT_APPROVED);

        let total_vp = staking::get_total_vp(staking_pool);
        let total_votes = proposal.total_vp_yes + proposal.total_vp_no;
        let quorum = total_vp * QUORUM_PERCENTAGE / 100;
        let yes_percentage = if (total_votes > 0) proposal.total_vp_yes * 100 / total_votes else 0;
        let min_yes_vp = total_vp * MIN_YES_VP_PERCENTAGE / 100;

        if (total_votes >= quorum && yes_percentage >= APPROVAL_PERCENTAGE && proposal.total_vp_yes >= min_yes_vp) {
            proposal.status = 1;
        } else {
            proposal.status = 2;
        }
    }

    public entry fun execute_proposal(
        governance: &mut GovernanceConfig,
        token_config: &mut TokenConfig,
        treasury: &mut TreasuryConfig,
        staking_pool: &mut StakePool,
        proposal_id: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&governance.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = table::borrow(&governance.proposals, proposal_id);
        assert!(proposal.status == 1, E_PROPOSAL_NOT_APPROVED);
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= proposal.end_time + EXECUTION_DELAY, E_EXECUTION_DELAY_NOT_PASSED);

        if (proposal.type == 0) {
            let (buy_tax_bp, transfer_tax_bp, sell_tax_bp) = decode_tax_rate_parameters(&proposal.parameters);
            token_management::update_tax_rates_from_governance(token_config, buy_tax_bp, transfer_tax_bp, sell_tax_bp, ctx);
        } else if (proposal.type == 1) {
            let new_thresholds = decode_staking_tier_parameters(&proposal.parameters);
            staking::update_tier_thresholds(staking_pool, new_thresholds, ctx);
        } else if (proposal.type == 2) {
            let (burn_pct, liquidity_pct, governance_pct, lp_staking_pct) = decode_allocation_parameters(&proposal.parameters);
            update_allocation_percentages(treasury, burn_pct, liquidity_pct, governance_pct, lp_staking_pct);
        } else {
            abort E_UNAUTHORIZED
        }
    }

    fun decode_tax_rate_parameters(parameters: &vector<u8>): (u64, u64, u64) {
        (read_u64(parameters, 0), read_u64(parameters, 8), read_u64(parameters, 16))
    }

    fun decode_staking_tier_parameters(parameters: &vector<u8>): vector<u64> {
        let mut thresholds = vector::empty<u64>();
        let mut i = 0;
        while (i < vector::length(parameters)) {
            vector::push_back(&mut thresholds, read_u64(parameters, i));
            i = i + 8;
        };
        thresholds
    }

    fun decode_allocation_parameters(parameters: &vector<u8>): (u64, u64, u64, u64) {
        (read_u64(parameters, 0), read_u64(parameters, 8), read_u64(parameters, 16), read_u64(parameters, 24))
    }

    fun read_u64(data: &vector<u8>, start: u64): u64 {
        let mut value = 0u64;
        let mut j = 0;
        while (j < 8) {
            value = (value << 8) | (*vector::borrow(data, start + j) as u64);
            j = j + 1;
        };
        value
    }

    fun update_allocation_percentages(
        treasury: &mut TreasuryConfig,
        burn_pct: u64,
        liquidity_pct: u64,
        governance_pct: u64,
        lp_staking_pct: u64
    ) {
        assert!(burn_pct + liquidity_pct + governance_pct + lp_staking_pct == 10000, E_UNAUTHORIZED);
        *table::borrow_mut(&mut treasury.allocation_percentages, b"burn") = burn_pct;
        *table::borrow_mut(&mut treasury.allocation_percentages, b"liquidity") = liquidity_pct;
        *table::borrow_mut(&mut treasury.allocation_percentages, b"governance") = governance_pct;
        *table::borrow_mut(&mut treasury.allocation_percentages, b"lp_staking") = lp_staking_pct;
    }
}