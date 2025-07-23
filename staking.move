module veralux::staking {
    use veralux::token_management::{Self, LUX};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::dynamic_object_field as dof;
    use sui::table::{Self, Table};

    // Errors
    const E_UNAUTHORIZED: u64 = 0;
    const E_LOCK_PERIOD_NOT_ENDED: u64 = 1;
    const E_INSUFFICIENT_STAKE: u64 = 2;

    // Structs
    struct StakePool has key {
        id: UID,
        total_staked: u64,
        rewards_per_share: u128,
        last_updated_epoch: u64,
        reward_per_epoch: u64,
    }

    struct StakeRegistry has key {
        id: UID,
        positions: Table<address, StakePosition>,
    }

    struct StakePosition has store {
        stake_amount: u64,
        reward_debt: u128,
        lock_end_epoch: u64,
    }

    // Events
    struct StakeEvent has copy, drop {
        user: address,
        amount: u64,
        epoch: u64,
    }

    struct UnstakeEvent has copy, drop {
        user: address,
        amount: u64,
        epoch: u64,
    }

    struct ClaimEvent has copy, drop {
        user: address,
        amount: u64,
        epoch: u64,
    }

    // Init: Create and share StakePool and StakeRegistry, attach empty coins
    #[init]
    public fun init(ctx: &mut TxContext) {
        let stake_pool = StakePool {
            id: object::new(ctx),
            total_staked: 0,
            rewards_per_share: 0,
            last_updated_epoch: tx_context::epoch(ctx),
            reward_per_epoch: 0,  // Set via set_reward_per_epoch
        };
        let stake_registry = StakeRegistry {
            id: object::new(ctx),
            positions: table::new<address, StakePosition>(ctx),
        };
        transfer::public_share_object(stake_pool);
        transfer::public_share_object(stake_registry);

        // Attach empty coins to StakePool
        let staked_coin = coin::zero<LUX>(ctx);
        dof::add(&mut stake_pool.id, b"staked_coin", staked_coin);
        let reward_coin = coin::zero<LUX>(ctx);
        dof::add(&mut stake_pool.id, b"reward_coin", reward_coin);
    }

    // Set reward rate (admin only)
    public entry fun set_reward_per_epoch(reward_per_epoch: u64, ctx: &mut TxContext) {
        let stake_pool = borrow_mut_stake_pool();
        assert!(tx_context::sender(ctx) == @0x0, E_UNAUTHORIZED);  // Replace @0x0 with admin address
        stake_pool.reward_per_epoch = reward_per_epoch;
    }

    // Add reward funds (admin only)
    public entry fun add_reward_funds(reward: Coin<LUX>, ctx: &mut TxContext) {
        let stake_pool = borrow_mut_stake_pool();
        assert!(tx_context::sender(ctx) == @0x0, E_UNAUTHORIZED);  // Replace @0x0 with admin address
        let reward_coin = dof::borrow_mut(&mut stake_pool.id, b"reward_coin");
        coin::join(reward_coin, reward);
    }

    // Stake tokens
    public entry fun stake(coin: &mut Coin<LUX>, amount: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let stake_pool = borrow_mut_stake_pool();
        let stake_registry = borrow_mut_stake_registry();
        assert!(amount > 0, E_INSUFFICIENT_STAKE);

        // Update pool rewards
        update_pool(stake_pool, ctx);

        // Get or create user position
        if (!table::contains(&stake_registry.positions, sender)) {
            table::add(&mut stake_registry.positions, sender, StakePosition {
                stake_amount: 0,
                reward_debt: 0,
                lock_end_epoch: 0,
            });
        };
        let position = table::borrow_mut(&mut stake_registry.positions, sender);

        // Claim existing rewards
        if (position.stake_amount > 0) {
            let claimable = ((position.stake_amount as u128) * stake_pool.rewards_per_share / 1_000_000_000_000_000_000) - position.reward_debt;
            if (claimable > 0) {
                let reward_coin = dof::borrow_mut(&mut stake_pool.id, b"reward_coin");
                let reward_part = coin::split(reward_coin, (claimable as u64), ctx);
                transfer::public_transfer(reward_part, sender);
                event::emit(ClaimEvent { user: sender, amount: (claimable as u64), epoch: tx_context::epoch(ctx) });
            };
        };

        // Transfer stake amount to pool
        let stake_part = coin::split(coin, amount, ctx);
        let staked_coin = dof::borrow_mut(&mut stake_pool.id, b"staked_coin");
        coin::join(staked_coin, stake_part);

        // Update position
        position.stake_amount = position.stake_amount + amount;
        position.lock_end_epoch = tx_context::epoch(ctx) + 5040;  // ~7 days (2 min/epoch)
        position.reward_debt = ((position.stake_amount as u128) * stake_pool.rewards_per_share / 1_000_000_000_000_000_000);

        // Update pool
        stake_pool.total_staked = stake_pool.total_staked + amount;

        event::emit(StakeEvent { user: sender, amount, epoch: tx_context::epoch(ctx) });
    }

    // Unstake tokens after lock period
    public entry fun unstake(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let stake_pool = borrow_mut_stake_pool();
        let stake_registry = borrow_mut_stake_registry();
        let position = table::borrow_mut(&mut stake_registry.positions, sender);
        assert!(tx_context::epoch(ctx) >= position.lock_end_epoch, E_LOCK_PERIOD_NOT_ENDED);
        assert!(position.stake_amount > 0, E_INSUFFICIENT_STAKE);

        // Update pool rewards
        update_pool(stake_pool, ctx);

        // Claim rewards
        let claimable = ((position.stake_amount as u128) * stake_pool.rewards_per_share / 1_000_000_000_000_000_000) - position.reward_debt;
        if (claimable > 0) {
            let reward_coin = dof::borrow_mut(&mut stake_pool.id, b"reward_coin");
            let reward_part = coin::split(reward_coin, (claimable as u64), ctx);
            transfer::public_transfer(reward_part, sender);
            event::emit(ClaimEvent { user: sender, amount: (claimable as u64), epoch: tx_context::epoch(ctx) });
        };

        // Withdraw staked amount
        let staked_coin = dof::borrow_mut(&mut stake_pool.id, b"staked_coin");
        let withdraw_part = coin::split(staked_coin, position.stake_amount, ctx);
        transfer::public_transfer(withdraw_part, sender);

        // Update pool and position
        stake_pool.total_staked = stake_pool.total_staked - position.stake_amount;
        let amount = position.stake_amount;
        position.stake_amount = 0;
        position.reward_debt = 0;
        position.lock_end_epoch = 0;

        event::emit(UnstakeEvent { user: sender, amount, epoch: tx_context::epoch(ctx) });
    }

    // Internal: Update pool rewards
    fun update_pool(stake_pool: &mut StakePool, ctx: &TxContext) {
        let current_epoch = tx_context::epoch(ctx);
        if (current_epoch > stake_pool.last_updated_epoch && stake_pool.total_staked > 0) {
            let epochs_passed = current_epoch - stake_pool.last_updated_epoch;
            let reward_added = (stake_pool.reward_per_epoch as u128) * (epochs_passed as u128);
            stake_pool.rewards_per_share = stake_pool.rewards_per_share + (reward_added * 1_000_000_000_000_000_000 / (stake_pool.total_staked as u128));
        };
        stake_pool.last_updated_epoch = current_epoch;
    }

    // Helpers: Borrow shared objects (replace IDs post-deployment)
    fun borrow_mut_stake_pool(): &mut StakePool {
        object::borrow_mut<StakePool>(@0xStakePoolID)  // Replace with actual ID after deployment
    }

    fun borrow_mut_stake_registry(): &mut StakeRegistry {
        object::borrow_mut<StakeRegistry>(@0xStakeRegistryID)  // Replace with actual ID after deployment
    }
}
