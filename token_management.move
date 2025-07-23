module veralux::token_management {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::vec;

    // Constants
    const TOTAL_SUPPLY: u64 = 100_000_000_000;  // 100B LUX
    const BASIS_POINTS: u64 = 10_000;  // For tax (4% = 400 bp)
    const DAILY_EPOCH_WINDOW: u64 = 720;  // ~24h (2 min/epoch)
    const TAX_TIMELOCK_EPOCHS: u64 = 2160;  // 72h
    const MAX_HISTORY: u64 = 100;  // Sell history cap

    // Errors
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

    // Structs
    struct LUX has drop {}

    struct TokenConfig has key {
        id: UID,
        total_minted: u64,
        mint_authority: address,
        tax_rate: u64,
        authorities: vector<address>,
        required_signers: u64,
        pause_flag: bool,
        pending_tax_rate: u64,
        timelock_end: u64,
        treasury_cap: TreasuryCap<LUX>,
        treasury_address: address,
        tax_change_confirmations: vector<address>,
    }

    struct UserRegistry has key {
        id: UID,
        users: Table<address, UserData>,
    }

    struct UserData has store {
        last_transfer_epoch: u64,
        sell_history: vector<(u64, u64)>,
    }

    // Events
    struct MintEvent has copy, drop {
        amount: u64,
        to: address,
        epoch: u64,
    }

    struct TransferEvent has copy, drop {
        from: address,
        to: address,
        amount: u64,
        tax: u64,
        epoch: u64,
        taxed: bool,
    }

    struct UpdateEvent has copy, drop {
        change: vector<u8>,
        epoch: u64,
    }

    // Init: Deploy token and distribute supply
    #[init]
    public fun init(ctx: &mut TxContext) {
        let metadata = coin::create_currency_metadata(
            LUX {},
            9,
            b"LUX",
            b"VeraLux Token",
            b"Native token for VeraLux ecosystem",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);

        let treasury_cap = coin::create_treasury_cap(LUX {}, ctx);

        let config = TokenConfig {
            id: object::new(ctx),
            total_minted: 0,
            mint_authority: tx_context::sender(ctx),
            tax_rate: 400,  // 4%
            authorities: vector[@0x0, @0x0, @0x0, @0x0, @0x0],  // Replace with actual addresses
            required_signers: 3,
            pause_flag: false,
            pending_tax_rate: 0,
            timelock_end: 0,
            treasury_cap,
            treasury_address: @0x0,  // Replace with actual address
            tax_change_confirmations: vector::empty(),
        };
        transfer::public_share_object(config);

        let registry = UserRegistry {
            id: object::new(ctx),
            users: table::new<address, UserData>(ctx),
        };
        transfer::public_share_object(registry);

        // Distribute supply
        let allocations = vector[
            (@0x0, TOTAL_SUPPLY / 10),  // Private sale: 10%
            (@0x0, TOTAL_SUPPLY / 10),  // Presale: 10%
            (@0x0, TOTAL_SUPPLY / 10),  // Liquidity: 10%
            (@0x0, TOTAL_SUPPLY / 5),   // Airdrop: 20%
            (@0x0, TOTAL_SUPPLY / 10),  // Staking: 10%
            (@0x0, TOTAL_SUPPLY * 15 / 100),  // Team: 15%
            (@0x0, TOTAL_SUPPLY / 4)    // Marketing: 25%
        ];
        let mut i = 0;
        while (i < vec::length(&allocations)) {
            let (to, amount) = vec::borrow(&allocations, i);
            mint_internal(&mut config, *to, *amount, ctx);
            event::emit(MintEvent { amount: *amount, to: *to, epoch: tx_context::epoch(ctx) });
            i = i + 1;
        };
    }

    // Internal mint function
    fun mint_internal(config: &mut TokenConfig, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == config.mint_authority, E_UNAUTHORIZED);
        assert!(config.total_minted + amount <= TOTAL_SUPPLY, E_SUPPLY_EXCEEDED);
        config.total_minted = config.total_minted + amount;
        coin::mint_and_transfer(&mut config.treasury_cap, amount, to, ctx);
    }

    // Transfer with tax
    public entry fun transfer(from: &mut Coin<LUX>, to: address, amount: u64, ctx: &mut TxContext) {
        let config = borrow_mut_config();
        let sender = tx_context::sender(ctx);

        if (sender == config.mint_authority || sender == config.treasury_address) {
            let part = coin::split(from, amount, ctx);
            transfer::public_transfer(part, to);
            event::emit(TransferEvent { from: sender, to, amount, tax: 0, epoch: tx_context::epoch(ctx), taxed: false });
            return;
        };

        assert!(!config.pause_flag, E_PAUSED);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(amount <= TOTAL_SUPPLY / 1000, E_SUPPLY_EXCEEDED);

        let registry = borrow_mut_registry();
        if (!table::contains(&registry.users, sender)) {
            table::add(&mut registry.users, sender, UserData {
                last_transfer_epoch: 0,
                sell_history: vec::empty(),
            });
        };
        let user_data = table::borrow_mut(&mut registry.users, sender);

        assert!(tx_context::epoch(ctx) > user_data.last_transfer_epoch, E_COOLDOWN_ACTIVE);
        user_data.last_transfer_epoch = tx_context::epoch(ctx);

        let history = &mut user_data.sell_history;
        let mut new_history = vec::empty<(u64, u64)>();
        let mut total_24h = 0;
        let current_epoch = tx_context::epoch(ctx);
        let mut i = 0;
        while (i < vec::length(history)) {
            let (ep, amt) = vec::borrow(history, i);
            if (current_epoch - *ep <= DAILY_EPOCH_WINDOW) {
                vec::push_back(&mut new_history, (*ep, *amt));
                total_24h = total_24h + *amt;
            };
            i = i + 1;
        };
        *history = new_history;
        assert!(vec::length(history) <= MAX_HISTORY, E_HISTORY_OVERFLOW);
        assert!(total_24h + amount <= TOTAL_SUPPLY / 1000, E_SUPPLY_EXCEEDED);
        vec::push_back(history, (current_epoch, amount));

        let tax_amount = (amount * config.tax_rate) / BASIS_POINTS;
        let net_amount = amount - tax_amount;
        let tax_part = coin::split(from, tax_amount, ctx);
        transfer::public_transfer(tax_part, config.treasury_address);
        let net_part = coin::split(from, net_amount, ctx);
        transfer::public_transfer(net_part, to);

        event::emit(TransferEvent { from: sender, to, amount: net_amount, tax: tax_amount, epoch: current_epoch, taxed: true });
    }

    // Multisig tax change functions
    public entry fun initiate_tax_change(new_tax_rate: u64, ctx: &mut TxContext) {
        let config = borrow_mut_config();
        let sender = tx_context::sender(ctx);
        assert!(vec::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pending_tax_rate == 0, E_TIMELOCK_ACTIVE);
        config.pending_tax_rate = new_tax_rate;
        config.tax_change_confirmations = vector[sender];
        config.timelock_end = tx_context::epoch(ctx) + TAX_TIMELOCK_EPOCHS;
    }

    public entry fun confirm_tax_change(ctx: &mut TxContext) {
        let config = borrow_mut_config();
        let sender = tx_context::sender(ctx);
        assert!(vec::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        assert!(config.pending_tax_rate != 0, E_INVALID_INPUT);
        if (!vec::contains(&config.tax_change_confirmations, &sender)) {
            vec::push_back(&mut config.tax_change_confirmations, sender);
        };
    }

    public entry fun execute_tax_change(ctx: &mut TxContext) {
        let config = borrow_mut_config();
        assert!(config.pending_tax_rate != 0, E_INVALID_INPUT);
        assert!(tx_context::epoch(ctx) >= config.timelock_end, E_TIMELOCK_ACTIVE);
        assert!(vec::length(&config.tax_change_confirmations) >= config.required_signers, E_UNAUTHORIZED);
        config.tax_rate = config.pending_tax_rate;
        config.pending_tax_rate = 0;
        config.tax_change_confirmations = vector::empty();
        config.timelock_end = 0;
        event::emit(UpdateEvent { change: b"tax_rate", epoch: tx_context::epoch(ctx) });
    }

    // Helpers (replace IDs post-deployment)
    fun borrow_mut_config(): &mut TokenConfig {
        object::borrow_mut<TokenConfig>(@0xTokenConfigID)  // Replace with actual ID
    }

    fun borrow_mut_registry(): &mut UserRegistry {
        object::borrow_mut<UserRegistry>(@0xUserRegistryID)  // Replace with actual ID
    }
}
