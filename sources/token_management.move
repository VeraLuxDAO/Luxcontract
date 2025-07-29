#[allow(duplicate_alias)]
module veralux::token_management {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::vector;

    // Token witness struct
    public struct TOKEN_MANAGEMENT has drop {}

    // Constants
    const TOTAL_SUPPLY: u128 = 100_000_000_000_000_000_000;  // 100B LUX with 9 decimals
    const BASIS_POINTS: u64 = 10_000;  // For percentage calculations
    const MAX_DAILY_SELL: u64 = 100_000_000_000_000_000;  // 0.1% of supply
    const MAX_DAILY_TRANSFER: u64 = 100_000_000_000_000_000;  // 0.1% of supply
    const COOLDOWN_MS: u64 = 60_000;  // 1 minute in milliseconds
    const DAILY_WINDOW_MS: u64 = 86_400_000;  // 24 hours in milliseconds
    const TIMELOCK_MS: u64 = 259_200_000;  // 72 hours in milliseconds
    const PAUSE_TIMELOCK_MS: u64 = 86_400_000;  // 24 hours in milliseconds

    // Error codes
    const E_INSUFFICIENT_BALANCE: u64 = 0;
    const E_SUPPLY_EXCEEDED: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_TAX_RATE: u64 = 3;
    const E_COOLDOWN_ACTIVE: u64 = 4;
    const E_PAUSED: u64 = 5;
    const E_TIMELOCK_ACTIVE: u64 = 6;
    const E_INVALID_AMOUNT: u64 = 7;
    const E_INVALID_ALLOCATIONS: u64 = 8;

    // Structs
    public struct TransactionRecord has copy, drop, store {
        timestamp_ms: u64,
        amount: u64,
    }

    public struct Allocation has copy, drop {
        to: address,
        amount: u64,
    }

    // Global configuration
    public struct TokenConfig has key, store {
        id: UID,
        total_minted: u64,
        mint_authority: address,
        staking_contract: address,
        treasury_address: address,
        marketing_address: address,
        lp_staking_address: address,
        governance_address: address,
        burn_address: address,
        tax_rate: u64,  // in basis points (200 = 2%)
        tax_allocations: vector<u64>,  // [burn, marketing, governance, lp_staking]
        authorities: vector<address>,
        required_signers: u64,
        pause_flag: bool,
        cumulative_burned: u64,
        pending_tax_rate: u64,
        pending_allocations: vector<u64>,
        tax_timelock_end: u64,
        tax_update_voters: vector<address>,
        pending_pause_flag: bool,
        pause_timelock_end: u64,
        pause_update_voters: vector<address>,
        treasury_cap: TreasuryCap<TOKEN_MANAGEMENT>,
        dex_addresses: vector<address>,
    }

    // User data registry
    public struct UserRegistry has key, store {
        id: UID,
        users: Table<address, UserData>,
    }

    public struct UserData has store {
        last_tx_timestamp: u64,
        sell_history: vector<TransactionRecord>,
        transfer_history: vector<TransactionRecord>,
    }

    // Events
    public struct MintEvent has copy, drop {
        amount: u64,
        to: address,
        timestamp: u64,
    }

    public struct TransferEvent has copy, drop {
        from: address,
        to: address,
        amount: u64,
        tax: u64,
        timestamp: u64,
        taxed: bool,
    }

    public struct TaxUpdateEvent has copy, drop {
        new_tax_rate: u64,
        new_allocations: vector<u64>,
        timestamp: u64,
    }

    public struct PauseEvent has copy, drop {
        paused: bool,
        timestamp: u64,
    }

    public struct BurnEvent has copy, drop {
        amount: u64,
        timestamp: u64,
    }

    // Initialization
    fun init(witness: TOKEN_MANAGEMENT, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9,
            b"LUX",
            b"VeraLux Token",
            b"Native token for the VeraLux ecosystem with deflationary mechanics",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);

        let config = TokenConfig {
            id: object::new(ctx),
            total_minted: 0,
            mint_authority: tx_context::sender(ctx),
            staking_contract: @0x1,
            treasury_address: @0x2,
            marketing_address: @0x3,
            lp_staking_address: @0x4,
            governance_address: @0x5,
            burn_address: @0x6,
            tax_rate: 200,  // 2% at launch
            tax_allocations: vector[2500, 2500, 2500, 2500],  // 25% each
            authorities: vector[@0x7, @0x8, @0x9, @0xa, @0xb],
            required_signers: 3,
            pause_flag: false,
            cumulative_burned: 0,
            pending_tax_rate: 0,
            pending_allocations: vector::empty(),
            tax_timelock_end: 0,
            tax_update_voters: vector::empty(),
            pending_pause_flag: false,
            pause_timelock_end: 0,
            pause_update_voters: vector::empty(),
            treasury_cap,
            dex_addresses: vector[@0xc, @0xd],  // Example DEX addresses
        };
        transfer::public_share_object(config);

        let registry = UserRegistry {
            id: object::new(ctx),
            users: table::new(ctx),
        };
        transfer::public_share_object(registry);
    }

    // Initial distribution
    public entry fun initial_distribution(config: &mut TokenConfig, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        assert!(config.total_minted == 0, E_SUPPLY_EXCEEDED);

        let allocations = vector[
            Allocation { to: @0xe, amount: (TOTAL_SUPPLY / 10) as u64 },  // Private sale: 10%
            Allocation { to: @0xf, amount: (TOTAL_SUPPLY / 10) as u64 },  // Presale: 10%
            Allocation { to: @0x10, amount: (TOTAL_SUPPLY / 10) as u64 }, // Liquidity: 10%
            Allocation { to: @0x11, amount: (TOTAL_SUPPLY / 5) as u64 },  // Airdrop: 20%
            Allocation { to: @0x12, amount: (TOTAL_SUPPLY / 10) as u64 }, // Staking: 10%
            Allocation { to: @0x13, amount: (TOTAL_SUPPLY * 15 / 100) as u64 }, // Team: 15%
            Allocation { to: @0x14, amount: (TOTAL_SUPPLY / 4) as u64 }   // Marketing: 25%
        ];

        let mut i = 0;
        while (i < vector::length(&allocations)) {
            let allocation = vector::borrow(&allocations, i);
            mint_internal(config, allocation.to, allocation.amount, ctx);
            event::emit(MintEvent { amount: allocation.amount, to: allocation.to, timestamp: tx_context::epoch(ctx) });
            i = i + 1;
        };
    }

    fun mint_internal(config: &mut TokenConfig, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(config.total_minted + amount <= (TOTAL_SUPPLY as u64), E_SUPPLY_EXCEEDED);
        config.total_minted = config.total_minted + amount;
        coin::mint_and_transfer(&mut config.treasury_cap, amount, to, ctx);
    }

    // Privileged transfer (no tax)
    public entry fun privileged_transfer(
        config: &TokenConfig,
        from: &mut Coin<TOKEN_MANAGEMENT>,
        to: address,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(
            sender == config.staking_contract || sender == config.treasury_address || sender == config.mint_authority,
            E_UNAUTHORIZED
        );
        assert!(amount <= coin::value(from), E_INSUFFICIENT_BALANCE);

        let transfer_coin = coin::split(from, amount, ctx);
        transfer::public_transfer(transfer_coin, to);

        event::emit(TransferEvent {
            from: sender,
            to,
            amount,
            tax: 0,
            timestamp: clock::timestamp_ms(clock),
            taxed: false
        });
    }

    // Regular transfer with tax
    public entry fun transfer(
        config: &mut TokenConfig,
        registry: &mut UserRegistry,
        from: &mut Coin<TOKEN_MANAGEMENT>,
        to: address,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = clock::timestamp_ms(clock);

        // Check for privileged senders
        if (sender == config.mint_authority || sender == config.staking_contract || sender == config.treasury_address) {
            privileged_transfer(config, from, to, amount, clock, ctx);
            return
        };

        // Allow zero-amount transfers when paused
        if (amount == 0) {
            assert!(!config.pause_flag, E_PAUSED);
            let transfer_coin = coin::split(from, 0, ctx);
            transfer::public_transfer(transfer_coin, to);
            event::emit(TransferEvent {
                from: sender,
                to,
                amount: 0,
                tax: 0,
                timestamp: current_timestamp,
                taxed: false
            });
            return
        };

        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(!config.pause_flag, E_PAUSED);
        assert!(amount <= coin::value(from), E_INSUFFICIENT_BALANCE);
        assert!(amount <= MAX_DAILY_TRANSFER, E_SUPPLY_EXCEEDED);

        // Initialize or get user data
        if (!table::contains(&registry.users, sender)) {
            table::add(&mut registry.users, sender, UserData {
                last_tx_timestamp: 0,
                sell_history: vector::empty(),
                transfer_history: vector::empty(),
            });
        };
        let user_data = table::borrow_mut(&mut registry.users, sender);

        // Cooldown check
        assert!(current_timestamp >= user_data.last_tx_timestamp + COOLDOWN_MS, E_COOLDOWN_ACTIVE);
        user_data.last_tx_timestamp = current_timestamp;

        // Determine if it's a sell or transfer
        let is_sell = vector::contains(&config.dex_addresses, &to);
        let history = if (is_sell) &mut user_data.sell_history else &mut user_data.transfer_history;
        let max_daily = if (is_sell) MAX_DAILY_SELL else MAX_DAILY_TRANSFER;

        // Clean old history and check daily limit
        let mut total_24h = 0;
        let mut i = 0;
        let mut new_history = vector::empty<TransactionRecord>();
        while (i < vector::length(history)) {
            let record = *vector::borrow(history, i);
            if (current_timestamp - record.timestamp_ms <= DAILY_WINDOW_MS) {
                vector::push_back(&mut new_history, record);
                total_24h = total_24h + record.amount;
            };
            i = i + 1;
        };
        *history = new_history;
        assert!(total_24h + amount <= max_daily, E_SUPPLY_EXCEEDED);

        // Calculate tax
        let tax_amount = safe_mul_div(amount, config.tax_rate, BASIS_POINTS);
        let net_amount = amount - tax_amount;

        // Process tax
        if (tax_amount > 0) {
            let tax_coin = coin::split(from, tax_amount, ctx);
            distribute_tax(config, tax_coin, ctx);  // Temporary internal distribution
        };

        // Transfer net amount
        let net_coin = coin::split(from, net_amount, ctx);
        transfer::public_transfer(net_coin, to);

        // Update history
        vector::push_back(history, TransactionRecord { timestamp_ms: current_timestamp, amount });

        event::emit(TransferEvent {
            from: sender,
            to,
            amount: net_amount,
            tax: tax_amount,
            timestamp: current_timestamp,
            taxed: true
        });
    }

    // Temporary tax distribution (replace with treasury module call)
    fun distribute_tax(config: &mut TokenConfig, mut tax_coin: Coin<TOKEN_MANAGEMENT>, ctx: &mut TxContext) {
        let tax_amount = coin::value(&tax_coin);
        let allocations = &config.tax_allocations;

        let burn_amount = safe_mul_div(tax_amount, *vector::borrow(allocations, 0), BASIS_POINTS);
        if (burn_amount > 0) {
            let burn_coin = coin::split(&mut tax_coin, burn_amount, ctx);
            let burned = coin::burn(&mut config.treasury_cap, burn_coin);
            config.cumulative_burned = config.cumulative_burned + burned;
            event::emit(BurnEvent { amount: burned, timestamp: tx_context::epoch(ctx) });
        };

        let marketing_amount = safe_mul_div(tax_amount, *vector::borrow(allocations, 1), BASIS_POINTS);
        if (marketing_amount > 0) {
            let marketing_coin = coin::split(&mut tax_coin, marketing_amount, ctx);
            transfer::public_transfer(marketing_coin, config.marketing_address);
        };

        let governance_amount = safe_mul_div(tax_amount, *vector::borrow(allocations, 2), BASIS_POINTS);
        if (governance_amount > 0) {
            let governance_coin = coin::split(&mut tax_coin, governance_amount, ctx);
            transfer::public_transfer(governance_coin, config.governance_address);
        };

        let lp_staking_amount = safe_mul_div(tax_amount, *vector::borrow(allocations, 3), BASIS_POINTS);
        if (lp_staking_amount > 0) {
            let lp_staking_coin = coin::split(&mut tax_coin, lp_staking_amount, ctx);
            transfer::public_transfer(lp_staking_coin, config.lp_staking_address);
        };

        if (coin::value(&tax_coin) > 0) {
            let dust_burned = coin::burn(&mut config.treasury_cap, tax_coin);
            config.cumulative_burned = config.cumulative_burned + dust_burned;
            event::emit(BurnEvent { amount: dust_burned, timestamp: tx_context::epoch(ctx) });
        } else {
            coin::destroy_zero(tax_coin);
        };
    }

    // Governance functions
    public entry fun propose_tax_update(
        config: &mut TokenConfig,
        new_tax_rate: u64,
        new_allocations: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.tax_timelock_end == 0, E_TIMELOCK_ACTIVE);
        assert!(new_tax_rate >= 100 && new_tax_rate <= 300, E_INVALID_TAX_RATE);  // 1-3%
        assert!(vector::length(&new_allocations) == 4, E_INVALID_ALLOCATIONS);
        assert!(vector_sum(&new_allocations) == BASIS_POINTS, E_INVALID_ALLOCATIONS);

        config.pending_tax_rate = new_tax_rate;
        config.pending_allocations = new_allocations;
        config.tax_timelock_end = clock::timestamp_ms(clock) + TIMELOCK_MS;
        config.tax_update_voters = vector[sender];
    }

    public entry fun vote_for_tax_update(config: &mut TokenConfig, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.tax_timelock_end > 0, E_TIMELOCK_ACTIVE);
        if (!vector::contains(&config.tax_update_voters, &sender)) {
            vector::push_back(&mut config.tax_update_voters, sender);
        };
    }

    public entry fun execute_tax_update(config: &mut TokenConfig, clock: &Clock, _ctx: &mut TxContext) {
        let current_timestamp = clock::timestamp_ms(clock);
        assert!(config.tax_timelock_end > 0 && current_timestamp >= config.tax_timelock_end, E_TIMELOCK_ACTIVE);
        assert!(vector::length(&config.tax_update_voters) >= config.required_signers, E_UNAUTHORIZED);

        config.tax_rate = config.pending_tax_rate;
        config.tax_allocations = config.pending_allocations;
        config.pending_tax_rate = 0;
        config.pending_allocations = vector::empty();
        config.tax_timelock_end = 0;
        config.tax_update_voters = vector::empty();

        event::emit(TaxUpdateEvent {
            new_tax_rate: config.tax_rate,
            new_allocations: config.tax_allocations,
            timestamp: current_timestamp
        });
    }

    public entry fun propose_pause(config: &mut TokenConfig, new_pause_flag: bool, clock: &Clock, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pause_timelock_end == 0, E_TIMELOCK_ACTIVE);
        assert!(new_pause_flag != config.pause_flag, E_INVALID_AMOUNT);

        config.pending_pause_flag = new_pause_flag;
        config.pause_timelock_end = clock::timestamp_ms(clock) + PAUSE_TIMELOCK_MS;
        config.pause_update_voters = vector[sender];
    }

    public entry fun vote_for_pause(config: &mut TokenConfig, _ctx: &mut TxContext) {
        let sender = tx_context::sender(_ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pause_timelock_end > 0, E_TIMELOCK_ACTIVE);
        if (!vector::contains(&config.pause_update_voters, &sender)) {
            vector::push_back(&mut config.pause_update_voters, sender);
        };
    }

    public entry fun execute_pause(config: &mut TokenConfig, clock: &Clock, _ctx: &mut TxContext) {
        let current_timestamp = clock::timestamp_ms(clock);
        assert!(config.pause_timelock_end > 0 && current_timestamp >= config.pause_timelock_end, E_TIMELOCK_ACTIVE);
        assert!(vector::length(&config.pause_update_voters) >= config.required_signers, E_UNAUTHORIZED);

        config.pause_flag = config.pending_pause_flag;
        config.pause_timelock_end = 0;
        config.pause_update_voters = vector::empty();

        event::emit(PauseEvent { paused: config.pause_flag, timestamp: current_timestamp });
    }

    // Utility functions
    fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        let result = (a as u128) * (b as u128) / (c as u128);
        (result as u64)
    }

    fun vector_sum(v: &vector<u64>): u64 {
        let mut sum = 0;
        let mut i = 0;
        while (i < vector::length(v)) {
            sum = sum + *vector::borrow(v, i);
            i = i + 1;
        };
        sum
    }

    // View functions
    public fun view_config(config: &TokenConfig): (u64, vector<u64>, bool, vector<address>, u64, u64) {
        (
            config.tax_rate,
            config.tax_allocations,
            config.pause_flag,
            config.authorities,
            config.required_signers,
            config.cumulative_burned
        )
    }

    public fun view_user_data(registry: &UserRegistry, user: address): (u64, vector<TransactionRecord>, vector<TransactionRecord>) {
        if (table::contains(&registry.users, user)) {
            let data = table::borrow(&registry.users, user);
            (data.last_tx_timestamp, data.sell_history, data.transfer_history)
        } else {
            (0, vector::empty(), vector::empty())
        }
    }
}