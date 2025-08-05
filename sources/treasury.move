module veralux::treasury {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::vector;
    use veralux::multisig::{Self, MultisigConfig};
    use veralux::token_management::{Self, TOKEN_MANAGEMENT, TokenConfig};

    const DAILY_WITHDRAWAL_LIMIT: u64 = 2_000_000_000_000_000_000; // 2% of 100B
    const TIMELOCK_THRESHOLD: u64 = 500_000_000_000_000_000; // 0.5% of 100B
    const DAILY_WINDOW_MS: u64 = 86_400_000; // 24 hours in milliseconds

    const E_UNAUTHORIZED: u64 = 0;
    const E_INSUFFICIENT_BALANCE: u64 = 1;
    const E_DAILY_LIMIT_EXCEEDED: u64 = 2;
    const E_ACTION_NOT_READY: u64 = 3;

    public struct TreasuryConfig has key, store {
        id: UID,
        liquidity_balance: Balance<TOKEN_MANAGEMENT>,
        governance_balance: Balance<TOKEN_MANAGEMENT>,
        lp_staking_balance: Balance<TOKEN_MANAGEMENT>,
        allocation_percentages: Table<vector<u8>, u64>, // e.g., b"burn" -> 2500 (25%)
        withdrawal_history: vector<WithdrawalRecord>,
    }

    public struct WithdrawalRecord has copy, drop, store {
        timestamp_ms: u64,
        amount: u64,
    }

    public struct TaxReceivedEvent has copy, drop {
        amount: u64,
        timestamp: u64,
    }

    public struct WithdrawalEvent has copy, drop {
        pool: vector<u8>,
        amount: u64,
        recipient: address,
        timestamp: u64,
    }

    fun init(ctx: &mut TxContext) {
        let config = TreasuryConfig {
            id: object::new(ctx),
            liquidity_balance: balance::zero<TOKEN_MANAGEMENT>(),
            governance_balance: balance::zero<TOKEN_MANAGEMENT>(),
            lp_staking_balance: balance::zero<TOKEN_MANAGEMENT>(),
            allocation_percentages: table::new(ctx),
            withdrawal_history: vector::empty(),
        };
        table::add(&mut config.allocation_percentages, b"burn", 2500); // 25% = 0.5% of 2%
        table::add(&mut config.allocation_percentages, b"liquidity", 2500);
        table::add(&mut config.allocation_percentages, b"governance", 2500);
        table::add(&mut config.allocation_percentages, b"lp_staking", 2500);
        transfer::share_object(config);
    }

    public entry fun receive_tax(
        treasury: &mut TreasuryConfig,
        token_config: &mut TokenConfig,
        tax_coin: Coin<TOKEN_MANAGEMENT>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let tax_amount = coin::value(&tax_coin);
        let timestamp = clock::timestamp_ms(clock);

        let burn_percentage = *table::borrow(&treasury.allocation_percentages, b"burn");
        let liquidity_percentage = *table::borrow(&treasury.allocation_percentages, b"liquidity");
        let governance_percentage = *table::borrow(&treasury.allocation_percentages, b"governance");
        let lp_staking_percentage = *table::borrow(&treasury.allocation_percentages, b"lp_staking");

        let burn_amount = safe_mul_div(tax_amount, burn_percentage, 10000);
        let liquidity_amount = safe_mul_div(tax_amount, liquidity_percentage, 10000);
        let governance_amount = safe_mul_div(tax_amount, governance_percentage, 10000);
        let lp_staking_amount = tax_amount - burn_amount - liquidity_amount - governance_amount;

        if (burn_amount > 0) {
            let burn_coin = coin::split(&mut tax_coin, burn_amount, ctx);
            coin::burn(&mut token_config.treasury_cap, burn_coin);
            token_config.cumulative_burned = token_config.cumulative_burned + burn_amount;
            event::emit(token_management::BurnEvent { amount: burn_amount, timestamp });
        };

        if (liquidity_amount > 0) {
            let liquidity_coin = coin::split(&mut tax_coin, liquidity_amount, ctx);
            balance::join(&mut treasury.liquidity_balance, coin::into_balance(liquidity_coin));
        };

        if (governance_amount > 0) {
            let governance_coin = coin::split(&mut tax_coin, governance_amount, ctx);
            balance::join(&mut treasury.governance_balance, coin::into_balance(governance_coin));
        };

        if (lp_staking_amount > 0) {
            let lp_staking_coin = coin::split(&mut tax_coin, lp_staking_amount, ctx);
            balance::join(&mut treasury.lp_staking_balance, coin::into_balance(lp_staking_coin));
        };

        coin::destroy_zero(tax_coin);

        event::emit(TaxReceivedEvent { amount: tax_amount, timestamp });
    }

    public entry fun withdraw(
        treasury: &mut TreasuryConfig,
        multisig: &MultisigConfig,
        action_id: u64,
        pool: vector<u8>,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(multisig::is_action_ready(multisig, action_id, clock), E_ACTION_NOT_READY);
        let (action_type, _, _) = multisig::get_action_details(multisig, action_id);
        assert!(action_type == b"withdraw", E_UNAUTHORIZED);

        let current_time = clock::timestamp_ms(clock);
        let total_withdrawn_24h = calculate_total_withdrawn_24h(treasury, current_time);
        assert!(total_withdrawn_24h + amount <= DAILY_WITHDRAWAL_LIMIT, E_DAILY_LIMIT_EXCEEDED);

        let balance = if (pool == b"liquidity") &mut treasury.liquidity_balance
                    else if (pool == b"governance") &mut treasury.governance_balance
                    else if (pool == b"lp_staking") &mut treasury.lp_staking_balance
                    else abort E_UNAUTHORIZED;

        assert!(balance::value(balance) >= amount, E_INSUFFICIENT_BALANCE);

        let withdraw_balance = balance::split(balance, amount);
        let withdraw_coin = coin::from_balance(withdraw_balance, ctx);
        transfer::public_transfer(withdraw_coin, recipient);

        vector::push_back(&mut treasury.withdrawal_history, WithdrawalRecord { timestamp_ms: current_time, amount });
        cleanup_withdrawal_history(treasury, current_time);
        multisig::remove_action(multisig, action_id);

        event::emit(WithdrawalEvent { pool, amount, recipient, timestamp: current_time });
    }

    fun calculate_total_withdrawn_24h(treasury: &TreasuryConfig, current_time: u64): u64 {
        let mut total = 0;
        let i = vector::length(&treasury.withdrawal_history);
        while (i > 0) {
            i = i - 1;
            let record = vector::borrow(&treasury.withdrawal_history, i);
            if (current_time - record.timestamp_ms <= DAILY_WINDOW_MS) {
                total = total + record.amount;
            } else {
                break;
            }
        };
        total
    }

    fun cleanup_withdrawal_history(treasury: &mut TreasuryConfig, current_time: u64) {
        let history = &mut treasury.withdrawal_history;
        while (!vector::is_empty(history)) {
            let record = vector::borrow(history, 0);
            if (current_time - record.timestamp_ms > DAILY_WINDOW_MS) {
                vector::remove(history, 0);
            } else {
                break;
            }
        }
    }

    fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        ((a as u128) * (b as u128) / (c as u128) as u64)
    }
}