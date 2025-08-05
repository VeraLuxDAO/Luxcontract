#[allow(duplicate_alias)]
module veralux::token_management {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};
    use std::vector;
    use std::option;

    // Token witness struct
    public struct TOKEN_MANAGEMENT has drop {}

    // Constants
    const TOTAL_SUPPLY: u128 = 100_000_000_000_000_000_000;  // 100B LUX with 9 decimals
    const MAX_DAILY_SELL: u64 = 100_000_000_000_000_000;  // 0.1% of supply
    const MAX_DAILY_TRANSFER: u64 = 100_000_000_000_000_000;  // 0.1% of supply
    const COOLDOWN_MS: u64 = 60_000;  // 1 minute in milliseconds
    const DAILY_WINDOW_MS: u64 = 86_400_000;  // 24 hours in milliseconds

    // Error codes
    const E_INSUFFICIENT_BALANCE: u64 = 0;
    const E_SUPPLY_EXCEEDED: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_COOLDOWN_ACTIVE: u64 = 4;
    const E_PAUSED: u64 = 5;
    const E_INVALID_AMOUNT: u64 = 7;

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
        authorities: vector<address>,
        required_signers: u64,
        pause_flag: bool,
        cumulative_burned: u64,
        treasury_cap: TreasuryCap<TOKEN_MANAGEMENT>,
        dex_addresses: vector<address>,
        phase: u8,              // 1 for Mainnet, 2 for Custom Fork
        buy_tax_bp: u64,        // Tax for buys (1% = 100 bp)
        transfer_tax_bp: u64,   // Tax for wallet-to-wallet (1% = 100 bp)
        sell_tax_bp: u64,       // Tax for sells (2% = 200 bp)
        exempt_addresses: vector<address>,  // Tax-exempt addresses
        // Tax treasury balances - collected taxes stored here
        burn_treasury: Balance<TOKEN_MANAGEMENT>,
        liquidity_treasury: Balance<TOKEN_MANAGEMENT>,
        governance_treasury: Balance<TOKEN_MANAGEMENT>,
        lp_staking_treasury: Balance<TOKEN_MANAGEMENT>,
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

    public struct BurnEvent has copy, drop {
        amount: u64,
        timestamp: u64,
    }

    public struct TaxCollectedEvent has copy, drop {
        total_tax: u64,
        burn_amount: u64,
        liquidity_amount: u64,
        governance_amount: u64,
        lp_staking_amount: u64,
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
            authorities: vector[@0x7, @0x8, @0x9, @0xa, @0xb],
            required_signers: 3,
            pause_flag: false,
            cumulative_burned: 0,
            treasury_cap,
            dex_addresses: vector[@0xc, @0xd],
            phase: 1,           // Start in Phase 1 (Mainnet)
            buy_tax_bp: 100,    // 1% tax for buys
            transfer_tax_bp: 100, // 1% tax for wallet-to-wallet
            sell_tax_bp: 200,   // 2% tax for sells
            exempt_addresses: vector[
                @0x1,  // Staking contract
                @0x2,  // Governance contract
                @0x3,  // Treasury contract
                @0x4,  // Airdrop contract
            ],
            burn_treasury: balance::zero<TOKEN_MANAGEMENT>(),
            liquidity_treasury: balance::zero<TOKEN_MANAGEMENT>(),
            governance_treasury: balance::zero<TOKEN_MANAGEMENT>(),
            lp_staking_treasury: balance::zero<TOKEN_MANAGEMENT>(),
        };
        transfer::share_object(config);

        let registry = UserRegistry {
            id: object::new(ctx),
            users: table::new(ctx),
        };
        transfer::share_object(registry);
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
            event::emit(MintEvent { 
                amount: allocation.amount, 
                to: allocation.to, 
                timestamp: tx_context::epoch_timestamp_ms(ctx) 
            });
            i = i + 1;
        };
    }

    fun mint_internal(config: &mut TokenConfig, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(config.total_minted + amount <= (TOTAL_SUPPLY as u64), E_SUPPLY_EXCEEDED);
        config.total_minted = config.total_minted + amount;
        coin::mint_and_transfer(&mut config.treasury_cap, amount, to, ctx);
    }

    // Transfer function with tax logic
   public entry fun transfer(
    config: &mut TokenConfig,
    treasury: &mut veralux::treasury::TreasuryConfig,
    registry: &mut UserRegistry,
    from: &mut Coin<TOKEN_MANAGEMENT>,
    to: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = clock::timestamp_ms(clock);
        let tax_bp = if (is_exempt(config, sender, to) || config.phase == 2) 0
                 else if (vector::contains(&config.dex_addresses, &to)) config.sell_tax_bp // 2%
                 else if (vector::contains(&config.dex_addresses, &sender)) config.buy_tax_bp // 1%
                 else config.transfer_tax_bp; // 1%
        let tax_amount = safe_mul_div(amount, tax_bp, 10000);
        let net_amount = amount - tax_amount
        if (tax_amount > 0) {
            let tax_coin = coin::split(from, tax_amount, ctx);
            veralux::treasury::receive_tax(treasury, config, tax_coin, clock, ctx);
            };
        let net_coin = coin::split(from, net_amount, ctx);
        transfer::public_transfer(net_coin, to);
        event::emit(TransferEvent { from: sender, to, amount: net_amount, tax: tax_amount, timestamp: current_timestamp, taxed: tax_bp > 0 });
        
        // Allow zero-amount transfers even when paused
        if (amount == 0) {
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

        assert!(!config.pause_flag, E_PAUSED);
        assert!(amount <= coin::value(from), E_INSUFFICIENT_BALANCE);

        // Check if transfer is exempt or in Phase 2 (no taxes)
        let is_exempt = is_exempt(config, sender, to);
        let tax_bp = if (is_exempt || config.phase == 2) {
            0 // No tax for exempt transfers or Phase 2
        } else if (vector::contains(&config.dex_addresses, &to)) {
            config.sell_tax_bp // 2% tax for sells (user to DEX)
        } else if (vector::contains(&config.dex_addresses, &sender)) {
            config.buy_tax_bp // 1% tax for buys (DEX to user)
        } else {
            config.transfer_tax_bp // 1% tax for wallet-to-wallet
        };

        let tax_amount = safe_mul_div(amount, tax_bp, 10000);
        let net_amount = amount - tax_amount;

        // Apply daily limits and cooldowns for non-exempt transfers
        if (!is_exempt) {
            if (!table::contains(&registry.users, sender)) {
                table::add(&mut registry.users, sender, UserData {
                    last_tx_timestamp: 0,
                    sell_history: vector::empty(),
                    transfer_history: vector::empty(),
                });
            };
            let user_data = table::borrow_mut(&mut registry.users, sender);

            assert!(current_timestamp >= user_data.last_tx_timestamp + COOLDOWN_MS, E_COOLDOWN_ACTIVE);
            user_data.last_tx_timestamp = current_timestamp;

            let is_sell = vector::contains(&config.dex_addresses, &to);
            let history = if (is_sell) &mut user_data.sell_history else &mut user_data.transfer_history;
            let max_daily = if (is_sell) MAX_DAILY_SELL else MAX_DAILY_TRANSFER;

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
            vector::push_back(history, TransactionRecord { timestamp_ms: current_timestamp, amount });
        };

        // Process tax distribution (0.5% each to 4 treasuries)
        if (tax_amount > 0) {
            let tax_coin = coin::split(from, tax_amount, ctx);
            distribute_tax(config, tax_coin, current_timestamp, ctx);
        };

        // Transfer net amount to recipient
        let net_coin = coin::split(from, net_amount, ctx);
        transfer::public_transfer(net_coin, to);

        event::emit(TransferEvent {
            from: sender,
            to,
            amount: net_amount,
            tax: tax_amount,
            timestamp: current_timestamp,
            taxed: tax_bp > 0
        });
    }

    // Distribute tax across 4 treasuries (0.5% each)
    fun distribute_tax(
        config: &mut TokenConfig, 
        tax_coin: Coin<TOKEN_MANAGEMENT>, 
        timestamp: u64,
        ctx: &mut TxContext
    ) {
        let total_tax = coin::value(&tax_coin);
        let mut tax_balance = coin::into_balance(tax_coin);
        
        // Split equally: 0.5% each = 25% of total tax each
        let quarter_tax = total_tax / 4;
        
        // Burn portion (0.5%)
        let burn_amount = quarter_tax;
        if (burn_amount > 0) {
            let burn_balance = balance::split(&mut tax_balance, burn_amount);
            let burn_coin = coin::from_balance(burn_balance, ctx);
            coin::burn(&mut config.treasury_cap, burn_coin);
            config.cumulative_burned = config.cumulative_burned + burn_amount;
            
            event::emit(BurnEvent {
                amount: burn_amount,
                timestamp
            });
        };
        
        // Distribute remaining to treasuries
        let liquidity_amount = quarter_tax;
        let governance_amount = quarter_tax;
        let lp_staking_amount = total_tax - burn_amount - liquidity_amount - governance_amount; // Remainder
        
        if (liquidity_amount > 0) {
            let liquidity_balance = balance::split(&mut tax_balance, liquidity_amount);
            balance::join(&mut config.liquidity_treasury, liquidity_balance);
        };
        
        if (governance_amount > 0) {
            let governance_balance = balance::split(&mut tax_balance, governance_amount);
            balance::join(&mut config.governance_treasury, governance_balance);
        };
        
        if (lp_staking_amount > 0) {
            let lp_staking_balance = balance::split(&mut tax_balance, lp_staking_amount);
            balance::join(&mut config.lp_staking_treasury, lp_staking_balance);
        };
        
        // Destroy any remaining dust
        balance::destroy_zero(tax_balance);
        
        event::emit(TaxCollectedEvent {
            total_tax,
            burn_amount,
            liquidity_amount,
            governance_amount,
            lp_staking_amount,
            timestamp
        });
    }

    // Check if a transfer is exempt from taxes
    fun is_exempt(config: &TokenConfig, sender: address, to: address): bool {
        config.phase == 2 || // Phase 2 has no taxes
        vector::contains(&config.exempt_addresses, &sender) || // Sender is exempt
        vector::contains(&config.exempt_addresses, &to)        // Recipient is exempt
    }

    // Utility function for safe multiplication and division
    fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        let result = (a as u128) * (b as u128) / (c as u128);
        (result as u64)
    }

    // Treasury withdrawal functions for authorized contracts
    public fun withdraw_from_liquidity_treasury(
        config: &mut TokenConfig, 
        amount: u64, 
        ctx: &mut TxContext
    ): Coin<TOKEN_MANAGEMENT> {
        // Only exempt addresses can withdraw
        assert!(vector::contains(&config.exempt_addresses, &tx_context::sender(ctx)), E_UNAUTHORIZED);
        assert!(balance::value(&config.liquidity_treasury) >= amount, E_INSUFFICIENT_BALANCE);
        
        let withdraw_balance = balance::split(&mut config.liquidity_treasury, amount);
        coin::from_balance(withdraw_balance, ctx)
    }

    public fun withdraw_from_governance_treasury(
        config: &mut TokenConfig, 
        amount: u64, 
        ctx: &mut TxContext
    ): Coin<TOKEN_MANAGEMENT> {
        assert!(vector::contains(&config.exempt_addresses, &tx_context::sender(ctx)), E_UNAUTHORIZED);
        assert!(balance::value(&config.governance_treasury) >= amount, E_INSUFFICIENT_BALANCE);
        
        let withdraw_balance = balance::split(&mut config.governance_treasury, amount);
        coin::from_balance(withdraw_balance, ctx)
    }

    public fun withdraw_from_lp_staking_treasury(
        config: &mut TokenConfig, 
        amount: u64, 
        ctx: &mut TxContext
    ): Coin<TOKEN_MANAGEMENT> {
        assert!(vector::contains(&config.exempt_addresses, &tx_context::sender(ctx)), E_UNAUTHORIZED);
        assert!(balance::value(&config.lp_staking_treasury) >= amount, E_INSUFFICIENT_BALANCE);
        
        let withdraw_balance = balance::split(&mut config.lp_staking_treasury, amount);
        coin::from_balance(withdraw_balance, ctx)
    }

    // Admin functions
    public entry fun add_exempt_address(config: &mut TokenConfig, addr: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        if (!vector::contains(&config.exempt_addresses, &addr)) {
            vector::push_back(&mut config.exempt_addresses, addr);
        };
    }

    public entry fun remove_exempt_address(config: &mut TokenConfig, addr: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        let (found, index) = vector::index_of(&config.exempt_addresses, &addr);
        if (found) {
            vector::remove(&mut config.exempt_addresses, index);
        };
    }

    public entry fun set_phase(config: &mut TokenConfig, new_phase: u8, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        assert!(new_phase == 1 || new_phase == 2, E_INVALID_AMOUNT);
        config.phase = new_phase;
    }

    public entry fun set_pause(config: &mut TokenConfig, paused: bool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        config.pause_flag = paused;
    }

    // View functions
    public fun view_config(config: &TokenConfig): (u64, u64, u64, u8, bool, vector<address>) {
        (
            config.buy_tax_bp,
            config.transfer_tax_bp,
            config.sell_tax_bp,
            config.phase,
            config.pause_flag,
            config.exempt_addresses
        )
    }

    public fun view_treasury_balances(config: &TokenConfig): (u64, u64, u64, u64) {
        (
            balance::value(&config.liquidity_treasury),
            balance::value(&config.governance_treasury),
            balance::value(&config.lp_staking_treasury),
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