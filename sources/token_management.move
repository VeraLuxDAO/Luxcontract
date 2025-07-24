module veralux::token_management {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::UID;
    use sui::tx_context::TxContext;
    use sui::event;
    use sui::table::{Self, Table};

    // Token witness struct - Must match module name in uppercase
    public struct TOKEN_MANAGEMENT has drop {}

    // Constants
    const TOTAL_SUPPLY: u128 = 100_000_000_000_000_000_000;  // 100B LUX with 9 decimals
    const BASIS_POINTS: u64 = 10_000;  // For percentage calculations
    const DAILY_EPOCH_WINDOW: u64 = 720;  // Approx 24h (~2 min per epoch)
    const TIMELOCK_EPOCHS: u64 = 2160;  // 72h for tax/authority changes
    const PAUSE_TIMELOCK_EPOCHS: u64 = 720;  // 24h for pause/unpause
    const MAX_HISTORY: u64 = 100;  // Cap for gas efficiency
    const MAX_DAILY_TRANSFER: u64 = 100_000_000_000_000_000;  // 0.1% of supply with decimals

    // Error codes
    const E_INSUFFICIENT_BALANCE: u64 = 0;
    const E_SUPPLY_EXCEEDED: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_TAX: u64 = 3;
    const E_COOLDOWN_ACTIVE: u64 = 4;
    const E_PAUSED: u64 = 5;
    const E_TIMELOCK_ACTIVE: u64 = 6;
    const E_INVALID_AMOUNT: u64 = 7;
    const E_HISTORY_OVERFLOW: u64 = 8;
    const E_INVALID_INPUT: u64 = 9;

    // Allocation struct to fix vector issue
    public struct Allocation has copy, drop {
        to: address,
        amount: u64,
    }

    // Global configuration
    public struct TokenConfig has key, store {
        id: UID,
        total_minted: u64,
        mint_authority: address,
        staking_contract: address,  // Exempt from tax
        treasury_address: address,  // Exempt from tax
        tax_rate: u64,
        tax_allocations: vector<u64>,  // [governance, liquidity, burn, staking]
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
        governance_address: address,
        liquidity_address: address,
        burn_address: address,  // Can be same as treasury for burning
    }

    // User data registry
    public struct UserRegistry has key, store {
        id: UID,
        users: Table<address, UserData>,
    }

    public struct UserData has store {
        last_transfer_epoch: u64,
        sell_history: vector<SellRecord>,
    }

    public struct SellRecord has store, copy, drop {
        epoch: u64,
        amount: u64,
    }

    // Events
    public struct MintEvent has copy, drop {
        amount: u64,
        to: address,
        epoch: u64,
    }

    public struct TransferEvent has copy, drop {
        from: address,
        to: address,
        amount: u64,
        tax: u64,
        epoch: u64,
        taxed: bool,
    }

    public struct UpdateEvent has copy, drop {
        change: vector<u8>,
        epoch: u64,
    }

    public struct PauseEvent has copy, drop {
        paused: bool,
        epoch: u64,
    }

    public struct BurnEvent has copy, drop {
        amount: u64,
        epoch: u64,
    }

    // Initialization function - Fixed witness type
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
        sui::transfer::public_freeze_object(metadata);

        let config = TokenConfig {
            id: sui::object::new(ctx),
            total_minted: 0,
            mint_authority: sui::tx_context::sender(ctx),
            staking_contract: @0x1,  // Replace after staking deployment
            treasury_address: @0x2,  // Replace with actual treasury
            tax_rate: 400,  // 4%
            tax_allocations: vector[2500, 2500, 2500, 2500],  // 25% each
            authorities: vector[
                @0x3, @0x4, @0x5, 
                @0x6, @0x7
            ],  // Replace with actual multisig addresses
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
            governance_address: @0x8,
            liquidity_address: @0x9,
            burn_address: @0xa,
        };
        sui::transfer::share_object(config);

        let registry = UserRegistry {
            id: sui::object::new(ctx),
            users: table::new<address, UserData>(ctx),
        };
        sui::transfer::share_object(registry);
    }

    // Initial distribution function (called after init) - Fixed vector usage
    public entry fun initial_distribution(config: &mut TokenConfig, ctx: &mut TxContext) {
        assert!(sui::tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        assert!(config.total_minted == 0, E_SUPPLY_EXCEEDED);  // Ensure only called once

        // Create proper allocation vector using struct
        let allocations = vector[
            Allocation { to: @0xb, amount: (TOTAL_SUPPLY / 10) as u64 },        // Private sale: 10%
            Allocation { to: @0xc, amount: (TOTAL_SUPPLY / 10) as u64 },        // Presale: 10%
            Allocation { to: @0xd, amount: (TOTAL_SUPPLY / 10) as u64 },        // Liquidity: 10%
            Allocation { to: @0xe, amount: (TOTAL_SUPPLY / 5) as u64 },         // Airdrop: 20%
            Allocation { to: @0xf, amount: (TOTAL_SUPPLY / 10) as u64 },        // Staking: 10%
            Allocation { to: @0x10, amount: (TOTAL_SUPPLY * 15 / 100) as u64 }, // Team: 15%
            Allocation { to: @0x11, amount: (TOTAL_SUPPLY / 4) as u64 }         // Marketing: 25%
        ];

        let mut i = 0;
        while (i < vector::length(&allocations)) {
            let allocation = vector::borrow(&allocations, i);
            mint_internal(config, allocation.to, allocation.amount, ctx);
            event::emit(MintEvent { 
                amount: allocation.amount, 
                to: allocation.to, 
                epoch: sui::tx_context::epoch(ctx) 
            });
            i = i + 1;
        };
    }

    // Internal mint function - Fixed generic type
    fun mint_internal(config: &mut TokenConfig, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(config.total_minted + amount <= (TOTAL_SUPPLY as u64), E_SUPPLY_EXCEEDED);
        config.total_minted = config.total_minted + amount;
        coin::mint_and_transfer(&mut config.treasury_cap, amount, to, ctx);
    }

    // Tax-exempt transfer for privileged addresses
    public entry fun privileged_transfer(
        config: &TokenConfig,
        from: &mut Coin<TOKEN_MANAGEMENT>, 
        to: address, 
        amount: u64, 
        ctx: &mut TxContext
    ) {
        let sender = sui::tx_context::sender(ctx);
        assert!(
            sender == config.staking_contract || 
            sender == config.treasury_address || 
            sender == config.mint_authority,
            E_UNAUTHORIZED
        );
        assert!(amount > 0 && amount <= coin::value(from), E_INVALID_AMOUNT);

        let transfer_coin = coin::split(from, amount, ctx);
        sui::transfer::public_transfer(transfer_coin, to);
        
        event::emit(TransferEvent { 
            from: sender, 
            to, 
            amount, 
            tax: 0, 
            epoch: sui::tx_context::epoch(ctx), 
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
        ctx: &mut TxContext
    ) {
        let sender = sui::tx_context::sender(ctx);
        
        // Check if sender is privileged (exempt from tax)
        if (sender == config.mint_authority || 
            sender == config.staking_contract || 
            sender == config.treasury_address) {
            privileged_transfer(config, from, to, amount, ctx);
            return
        };

        // Regular transfer checks
        assert!(!config.pause_flag, E_PAUSED);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(amount <= coin::value(from), E_INSUFFICIENT_BALANCE);
        assert!(amount <= MAX_DAILY_TRANSFER, E_SUPPLY_EXCEEDED);

        // Initialize or get user data
        if (!table::contains(&registry.users, sender)) {
            table::add(&mut registry.users, sender, UserData {
                last_transfer_epoch: 0,
                sell_history: vector::empty(),
            });
        };
        let user_data = table::borrow_mut(&mut registry.users, sender);

        // Cooldown check
        assert!(sui::tx_context::epoch(ctx) > user_data.last_transfer_epoch, E_COOLDOWN_ACTIVE);
        user_data.last_transfer_epoch = sui::tx_context::epoch(ctx);

        // Update and check daily transfer history
        update_transfer_history(user_data, amount, ctx);

        // Calculate and apply tax
        let tax_amount = (amount * config.tax_rate) / BASIS_POINTS;
        let net_amount = amount - tax_amount;

        // Process tax distribution
        if (tax_amount > 0) {
            let tax_coin = coin::split(from, tax_amount, ctx);
            distribute_tax(config, tax_coin, ctx);
        };

        // Transfer net amount
        let net_coin = coin::split(from, net_amount, ctx);
        sui::transfer::public_transfer(net_coin, to);

        event::emit(TransferEvent { 
            from: sender, 
            to, 
            amount: net_amount, 
            tax: tax_amount, 
            epoch: sui::tx_context::epoch(ctx), 
            taxed: true 
        });
    }

    // Internal function to distribute tax
    fun distribute_tax(config: &mut TokenConfig, mut tax_coin: Coin<TOKEN_MANAGEMENT>, ctx: &mut TxContext) {
        let tax_amount = coin::value(&tax_coin);
        let allocations = &config.tax_allocations;
        
        // Governance allocation
        let gov_amount = (tax_amount * *vector::borrow(allocations, 0)) / BASIS_POINTS;
        if (gov_amount > 0) {
            let gov_coin = coin::split(&mut tax_coin, gov_amount, ctx);
            sui::transfer::public_transfer(gov_coin, config.governance_address);
        };
        
        // Liquidity allocation
        let lp_amount = (tax_amount * *vector::borrow(allocations, 1)) / BASIS_POINTS;
        if (lp_amount > 0) {
            let lp_coin = coin::split(&mut tax_coin, lp_amount, ctx);
            sui::transfer::public_transfer(lp_coin, config.liquidity_address);
        };
        
        // Burn allocation
        let burn_amount = (tax_amount * *vector::borrow(allocations, 2)) / BASIS_POINTS;
        if (burn_amount > 0) {
            let burn_coin = coin::split(&mut tax_coin, burn_amount, ctx);
            let burned = coin::burn(&mut config.treasury_cap, burn_coin);
            config.cumulative_burned = config.cumulative_burned + burned;
            event::emit(BurnEvent { amount: burned, epoch: sui::tx_context::epoch(ctx) });
        };
        
        // Staking allocation
        let staking_amount = (tax_amount * *vector::borrow(allocations, 3)) / BASIS_POINTS;
        if (staking_amount > 0) {
            let staking_coin = coin::split(&mut tax_coin, staking_amount, ctx);
            sui::transfer::public_transfer(staking_coin, config.staking_contract);
        };

        // Burn any remaining dust
        if (coin::value(&tax_coin) > 0) {
            let dust_burned = coin::burn(&mut config.treasury_cap, tax_coin);
            config.cumulative_burned = config.cumulative_burned + dust_burned;
        } else {
            coin::destroy_zero(tax_coin);
        };
    }

    // Update user transfer history
    fun update_transfer_history(user_data: &mut UserData, amount: u64, ctx: &mut TxContext) {
        let current_epoch = sui::tx_context::epoch(ctx);
        let history = &mut user_data.sell_history;
        
        // Clean old history and calculate 24h total
        let mut new_history = vector::empty<SellRecord>();
        let mut total_24h = 0;
        let mut i = 0;
        while (i < vector::length(history)) {
            let record = *vector::borrow(history, i);
            if (current_epoch - record.epoch <= DAILY_EPOCH_WINDOW) {
                vector::push_back(&mut new_history, record);
                total_24h = total_24h + record.amount;
            };
            i = i + 1;
        };
        
        *history = new_history;
        assert!(vector::length(history) <= MAX_HISTORY, E_HISTORY_OVERFLOW);
        assert!(total_24h + amount <= MAX_DAILY_TRANSFER, E_SUPPLY_EXCEEDED);
        
        // Add current transfer to history
        vector::push_back(history, SellRecord { epoch: current_epoch, amount });
    }

    // Governance functions for tax updates
    public entry fun propose_tax_update(
        config: &mut TokenConfig,
        new_tax_rate: u64, 
        new_allocations: vector<u64>, 
        ctx: &mut TxContext
    ) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.tax_timelock_end == 0, E_TIMELOCK_ACTIVE);
        assert!(new_tax_rate <= 1000, E_INVALID_TAX);  // Max 10% tax
        assert!(vector::length(&new_allocations) == 4, E_INVALID_TAX);
        assert!(vector_sum(&new_allocations) == BASIS_POINTS, E_INVALID_TAX);
        
        config.pending_tax_rate = new_tax_rate;
        config.pending_allocations = new_allocations;
        config.tax_timelock_end = sui::tx_context::epoch(ctx) + TIMELOCK_EPOCHS;
        config.tax_update_voters = vector[sender];
    }

    public entry fun vote_for_tax_update(config: &mut TokenConfig, ctx: &mut TxContext) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.tax_timelock_end > 0, E_INVALID_INPUT);
        
        if (!vector::contains(&config.tax_update_voters, &sender)) {
            vector::push_back(&mut config.tax_update_voters, sender);
        };
    }

    public entry fun execute_tax_update(config: &mut TokenConfig, ctx: &mut TxContext) {
        assert!(config.tax_timelock_end > 0, E_TIMELOCK_ACTIVE);
        assert!(sui::tx_context::epoch(ctx) >= config.tax_timelock_end, E_TIMELOCK_ACTIVE);
        assert!(vector::length(&config.tax_update_voters) >= config.required_signers, E_UNAUTHORIZED);
        
        config.tax_rate = config.pending_tax_rate;
        config.tax_allocations = config.pending_allocations;
        config.pending_tax_rate = 0;
        config.pending_allocations = vector::empty();
        config.tax_timelock_end = 0;
        config.tax_update_voters = vector::empty();
        
        event::emit(UpdateEvent { 
            change: b"tax_rate_and_allocations", 
            epoch: sui::tx_context::epoch(ctx) 
        });
    }

    // Pause functionality
    public entry fun propose_pause(config: &mut TokenConfig, new_pause_flag: bool, ctx: &mut TxContext) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pause_timelock_end == 0, E_TIMELOCK_ACTIVE);
        assert!(new_pause_flag != config.pause_flag, E_INVALID_INPUT);
        
        config.pending_pause_flag = new_pause_flag;
        config.pause_timelock_end = sui::tx_context::epoch(ctx) + PAUSE_TIMELOCK_EPOCHS;
        config.pause_update_voters = vector[sender];
    }

    public entry fun vote_for_pause(config: &mut TokenConfig, ctx: &mut TxContext) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pause_timelock_end > 0, E_INVALID_INPUT);
        
        if (!vector::contains(&config.pause_update_voters, &sender)) {
            vector::push_back(&mut config.pause_update_voters, sender);
        };
    }

    public entry fun execute_pause(config: &mut TokenConfig, ctx: &mut TxContext) {
        assert!(config.pause_timelock_end > 0, E_TIMELOCK_ACTIVE);
        assert!(sui::tx_context::epoch(ctx) >= config.pause_timelock_end, E_TIMELOCK_ACTIVE);
        assert!(vector::length(&config.pause_update_voters) >= config.required_signers, E_UNAUTHORIZED);
        
        config.pause_flag = config.pending_pause_flag;
        config.pause_timelock_end = 0;
        config.pause_update_voters = vector::empty();
        
        event::emit(PauseEvent { paused: config.pause_flag, epoch: sui::tx_context::epoch(ctx) });
    }

    // Administrative function to update privileged addresses
    public entry fun update_privileged_addresses(
        config: &mut TokenConfig,
        new_staking_contract: address,
        new_treasury: address,
        ctx: &mut TxContext
    ) {
        assert!(sui::tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        config.staking_contract = new_staking_contract;
        config.treasury_address = new_treasury;
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

    public fun view_user_data(registry: &UserRegistry, user: address): (u64, vector<SellRecord>) {
        if (table::contains(&registry.users, user)) {
            let data = table::borrow(&registry.users, user);
            (data.last_transfer_epoch, data.sell_history)
        } else {
            (0, vector::empty())
        }
    }

    public fun get_total_supply(): u128 {
        TOTAL_SUPPLY
    }

    // Utility functions
    fun vector_sum(v: &vector<u64>): u64 {
        let mut sum = 0;
        let mut i = 0;
        while (i < vector::length(v)) {
            sum = sum + *vector::borrow(v, i);
            i = i + 1;
        };
        sum
    }
}
