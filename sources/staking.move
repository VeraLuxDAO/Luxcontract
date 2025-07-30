#[allow(duplicate_alias)]
module veralux::staking {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use std::vector;
    use veralux::token_management::{TOKEN_MANAGEMENT, TokenConfig};

    public struct STAKING has drop {}

    // Constants
    const SECONDS_PER_WEEK: u64 = 604_800;
    const SECONDS_PER_DAY: u64 = 86_400;
    const MAX_ACCRUAL_WEEKS: u64 = 4;

    const TIER_MIN_STAKES: vector<u64> = vector[
        250_000_000_000_000,  // 250K LUX
        500_000_000_000_000,  // 500K LUX
        1_250_000_000_000_000, // 1.25M LUX
        5_000_000_000_000_000  // 5M LUX
    ];
    const TIER_LOCK_PERIODS: vector<u64> = vector[7 * SECONDS_PER_DAY, 14 * SECONDS_PER_DAY, 30 * SECONDS_PER_DAY, 30 * SECONDS_PER_DAY];
    const TIER_VP: vector<u64> = vector[1, 3, 10, 25];
    const TIER_WEEKLY_REWARDS: vector<u64> = vector[
        7_000_000_000_000,   // 7K LUX
        14_000_000_000_000,  // 14K LUX
        36_000_000_000_000,  // 36K LUX
        144_000_000_000_000  // 144K LUX
    ];

    // Error codes
    const E_INSUFFICIENT_STAKE: u64 = 0;
    const E_INVALID_TIER: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_LOCK_ACTIVE: u64 = 3;
    const E_NO_REWARDS: u64 = 4;
    const E_STAKE_EXISTS: u64 = 5;
    const E_INSUFFICIENT_BALANCE: u64 = 6;
    const E_CLAIM_TOO_SOON: u64 = 7;
    const E_PAUSED: u64 = 8;
    const E_COOLDOWN_ACTIVE: u64 = 9;

    public struct StakePool has key, store {
        id: UID,
        total_staked: u64,
        reward_pool: Balance<TOKEN_MANAGEMENT>,
        admin: address,
        paused: bool,
        total_vp: u64,
        positions: Table<address, ID>,
        user_data: Table<address, UserStakeData>,
        apr_bp: u64,
        last_apr_adjustment: u64,
    }

    public struct UserStakeData has store {
        cooldown_end: u64, // Timestamp when cooldown ends after unstaking
    }

    public struct StakePosition has key, store {
        id: UID,
        owner: address,
        amount: u64,
        tier: u64,
        stake_timestamp: u64,
        lock_end_timestamp: u64,
        last_claim_timestamp: u64,
        unclaimed_rewards: u64,
        vp: u64,
    }

    // Events
    public struct StakeEvent has copy, drop {
        user: address,
        amount: u64,
        tier: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct UnstakeEvent has copy, drop {
        user: address,
        amount: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct ClaimEvent has copy, drop {
        user: address,
        amount: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct APRUpdateEvent has copy, drop {
        new_apr_bp: u64,
        timestamp: u64,
    }

    public struct RewardsForfeitedEvent has copy, drop {
        user: address,
        amount: u64,
        timestamp: u64,
    }

    fun init(_witness: STAKING, ctx: &mut TxContext) {
        let pool = StakePool {
            id: object::new(ctx),
            total_staked: 0,
            reward_pool: balance::zero<TOKEN_MANAGEMENT>(),
            admin: tx_context::sender(ctx),
            paused: false,
            total_vp: 0,
            positions: table::new(ctx),
            user_data: table::new(ctx),
            apr_bp: 15000,  // 150%
            last_apr_adjustment: 0,
        };
        transfer::share_object(pool);
    }

    // Stake tokens (tax-exempt via TokenConfig)
    public entry fun stake(
        pool: &mut StakePool,
        _token_config: &mut TokenConfig,
        tokens: Coin<TOKEN_MANAGEMENT>,
        tier: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let amount = coin::value(&tokens);
        let current_timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(!pool.paused, E_PAUSED);
        assert!(tier >= 1 && tier <= 4, E_INVALID_TIER);
        if (table::contains(&pool.user_data, sender)) {
            let user_data = table::borrow(&pool.user_data, sender);
            assert!(current_timestamp >= user_data.cooldown_end, E_COOLDOWN_ACTIVE);
        };
        assert!(!table::contains(&pool.positions, sender), E_STAKE_EXISTS);
        
        let tier_min_stakes = TIER_MIN_STAKES;
        assert!(amount >= *vector::borrow(&tier_min_stakes, tier - 1), E_INSUFFICIENT_STAKE);

        // No tax on staking - tokens go directly to reward pool
        let stake_balance = coin::into_balance(tokens);
        balance::join(&mut pool.reward_pool, stake_balance);

        let tier_lock_periods = TIER_LOCK_PERIODS;
        let lock_period = *vector::borrow(&tier_lock_periods, tier - 1);
        let position = StakePosition {
            id: object::new(ctx),
            owner: sender,
            amount,
            tier,
            stake_timestamp: current_timestamp,
            lock_end_timestamp: current_timestamp + lock_period,
            last_claim_timestamp: current_timestamp,
            unclaimed_rewards: 0,
            vp: 0, // VP starts at 0, earned after lock period
        };

        let position_id = object::id(&position);
        pool.total_staked = pool.total_staked + amount;
        table::add(&mut pool.positions, sender, position_id);

        transfer::transfer(position, sender);
        update_apr(pool, clock);

        event::emit(StakeEvent {
            user: sender,
            amount,
            tier,
            timestamp: current_timestamp,
            position_id,
        });
    }

    // Unstake with 7-day cooldown - VP and everything resets
    public entry fun unstake(
        pool: &mut StakePool,
        _token_config: &mut TokenConfig,
        mut position: StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(!pool.paused, E_PAUSED);
        assert!(current_timestamp >= position.lock_end_timestamp, E_LOCK_ACTIVE);

        // Claim any pending rewards before unstaking
        claim_rewards_internal(pool, &mut position, current_timestamp, ctx);

        let amount = position.amount;

        // Return staked tokens (no tax on unstaking)
        if (balance::value(&pool.reward_pool) >= amount) {
            let return_balance = balance::split(&mut pool.reward_pool, amount);
            let return_coin = coin::from_balance(return_balance, ctx);
            transfer::public_transfer(return_coin, sender);
        };

        // Reset VP and remove from total VP
        if (position.vp > 0) {
            pool.total_vp = pool.total_vp - position.vp;
        };

        pool.total_staked = pool.total_staked - amount;
        table::remove(&mut pool.positions, sender);

        // Set 7-day cooldown - everything resets
        if (table::contains(&pool.user_data, sender)) {
            let user_data = table::borrow_mut(&mut pool.user_data, sender);
            user_data.cooldown_end = current_timestamp + 7 * SECONDS_PER_DAY;
        } else {
            table::add(&mut pool.user_data, sender, UserStakeData { 
                cooldown_end: current_timestamp + 7 * SECONDS_PER_DAY 
            });
        };

        let position_id = object::id(&position);
        event::emit(UnstakeEvent {
            user: sender,
            amount,
            timestamp: current_timestamp,
            position_id,
        });

        // Delete the position object
        let StakePosition { 
            id, 
            owner: _, 
            amount: _, 
            tier: _, 
            stake_timestamp: _, 
            lock_end_timestamp: _, 
            last_claim_timestamp: _, 
            unclaimed_rewards: _, 
            vp: _ 
        } = position;
        object::delete(id);
    }

    // Claim rewards - forfeit unclaimed rewards after 4 weeks
    public entry fun claim_rewards(
        pool: &mut StakePool,
        position: &mut StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(!pool.paused, E_PAUSED);
        assert!(position.amount > 0, E_NO_REWARDS);

        claim_rewards_internal(pool, position, current_timestamp, ctx);
        update_apr(pool, clock);
    }

    fun claim_rewards_internal(
        pool: &mut StakePool,
        position: &mut StakePosition,
        current_timestamp: u64,
        ctx: &mut TxContext
    ) {
        // Update VP if lock period is complete
        update_vp(pool, position, current_timestamp);

        // Must be staked for at least 14 days before first reward claim
        let time_since_stake = current_timestamp - position.stake_timestamp;
        assert!(time_since_stake >= 14 * SECONDS_PER_DAY, E_CLAIM_TOO_SOON);

        // Must wait at least 24 hours between claims
        let time_since_last_claim = current_timestamp - position.last_claim_timestamp;
        assert!(time_since_last_claim >= SECONDS_PER_DAY, E_CLAIM_TOO_SOON);

        let weeks_elapsed = time_since_last_claim / SECONDS_PER_WEEK;
        if (weeks_elapsed == 0) return;

        let tier_weekly_rewards = TIER_WEEKLY_REWARDS;
        let weekly_reward = *vector::borrow(&tier_weekly_rewards, position.tier - 1);
        let claimable_weeks = if (weeks_elapsed > MAX_ACCRUAL_WEEKS) MAX_ACCRUAL_WEEKS else weeks_elapsed;
        let reward_amount = safe_mul(weekly_reward, claimable_weeks);

        // Forfeit excess rewards after 4 weeks of no claiming - return to reward pool
        if (weeks_elapsed > MAX_ACCRUAL_WEEKS) {
            let excess_weeks = weeks_elapsed - MAX_ACCRUAL_WEEKS;
            let excess_reward = safe_mul(weekly_reward, excess_weeks);
            
            event::emit(RewardsForfeitedEvent {
                user: position.owner,
                amount: excess_reward,
                timestamp: current_timestamp,
            });
            // Excess rewards stay in the pool (already there)
        };

        // Pay out claimable rewards (no tax on reward claims)
        if (reward_amount > 0 && balance::value(&pool.reward_pool) >= reward_amount) {
            let reward_balance = balance::split(&mut pool.reward_pool, reward_amount);
            let reward_coin = coin::from_balance(reward_balance, ctx);
            transfer::public_transfer(reward_coin, position.owner);
        };

        // Update last claim timestamp by full weeks elapsed
        position.last_claim_timestamp = position.last_claim_timestamp + (weeks_elapsed * SECONDS_PER_WEEK);

        event::emit(ClaimEvent {
            user: position.owner,
            amount: reward_amount,
            timestamp: current_timestamp,
            position_id: object::id(position),
        });
    }

    // Update voting power after lock period completes
    fun update_vp(pool: &mut StakePool, position: &mut StakePosition, current_timestamp: u64) {
        if (current_timestamp >= position.lock_end_timestamp && position.vp == 0) {
            let tier_vp = TIER_VP;
            let vp = *vector::borrow(&tier_vp, position.tier - 1);
            position.vp = vp;
            pool.total_vp = pool.total_vp + vp;
        };
    }

    // Update APR based on pool balance thresholds
    fun update_apr(pool: &mut StakePool, clock: &Clock) {
        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        let time_since_last = current_timestamp - pool.last_apr_adjustment;
        if (time_since_last < SECONDS_PER_WEEK) return;

        let pool_balance = pool.total_staked + balance::value(&pool.reward_pool);
        let new_apr = if (pool_balance > 7_500_000_000_000_000_000) 15000      // >7.5B: 150%
                      else if (pool_balance > 5_000_000_000_000_000_000) 11250 // ≤7.5B to >5B: 112.5%
                      else if (pool_balance > 2_500_000_000_000_000_000) 7500  // ≤5B to >2.5B: 75%
                      else 3750;                                               // ≤2.5B: 37.5%

        if (new_apr != pool.apr_bp) {
            pool.apr_bp = new_apr;
            pool.last_apr_adjustment = current_timestamp;
            event::emit(APRUpdateEvent { 
                new_apr_bp: new_apr, 
                timestamp: current_timestamp 
            });
        };
    }

    // Utility functions
    fun safe_mul(a: u64, b: u64): u64 {
        let result = (a as u128) * (b as u128);
        (result as u64)
    }

    // View functions
    public fun view_position(position: &StakePosition): (u64, u64, u64, u64, u64) {
        (position.amount, position.tier, position.lock_end_timestamp, position.last_claim_timestamp, position.vp)
    }

    public fun view_pool(pool: &StakePool): (u64, u64, u64, u64) {
        (pool.total_staked, balance::value(&pool.reward_pool), pool.total_vp, pool.apr_bp)
    }

    public fun get_user_cooldown(pool: &StakePool, user: address): u64 {
        if (table::contains(&pool.user_data, user)) {
            table::borrow(&pool.user_data, user).cooldown_end
        } else {
            0
        }
    }

    // Admin functions
    public entry fun set_paused(pool: &mut StakePool, paused: bool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        pool.paused = paused;
    }

    // Add funds to reward pool (for initial funding or top-ups)
    public entry fun fund_reward_pool(
        pool: &mut StakePool,
        tokens: Coin<TOKEN_MANAGEMENT>,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        let funding_balance = coin::into_balance(tokens);
        balance::join(&mut pool.reward_pool, funding_balance);
    }

    // Emergency withdraw (only when paused)
    public entry fun emergency_withdraw(
        pool: &mut StakePool,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        assert!(pool.paused, E_PAUSED);
        assert!(balance::value(&pool.reward_pool) >= amount, E_INSUFFICIENT_BALANCE);
        
        let withdraw_balance = balance::split(&mut pool.reward_pool, amount);
        let withdraw_coin = coin::from_balance(withdraw_balance, ctx);
        transfer::public_transfer(withdraw_coin, pool.admin);
    }
}