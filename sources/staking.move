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
    use veralux::token_management::{TOKEN_MANAGEMENT}; // Fixed import

    // Witness struct for module initialization
    public struct STAKING has drop {}

    // Constants
    const BASIS_POINTS: u64 = 10_000;  // For APR and percentage calculations
    const SECONDS_PER_YEAR: u64 = 31_536_000;  // 365 * 24 * 60 * 60
    const REWARD_CALCULATION_WINDOW: u64 = 86400;  // 24 hours in seconds
    
    // Tier requirements (with 9 decimals)
    const MIN_STAKE_TIER_1: u64 = 250_000_000_000_000;  // 250K LUX
    const MIN_STAKE_TIER_2: u64 = 1_000_000_000_000_000;  // 1M LUX
    const MIN_STAKE_TIER_3: u64 = 5_000_000_000_000_000;  // 5M LUX
    
    // Lock and cooldown periods (in seconds)
    const LOCK_PERIOD: u64 = 604800;  // 7 days
    const COOLDOWN_PERIOD: u64 = 604800;  // 7 days
    
    // Reward limits
    const MAX_WEEKLY_REWARDS_TIER_1: u64 = 10_000_000_000_000;  // 10K LUX per week
    const MAX_WEEKLY_REWARDS_TIER_2: u64 = 25_000_000_000_000;  // 25K LUX per week
    const MAX_WEEKLY_REWARDS_TIER_3: u64 = 50_000_000_000_000;  // 50K LUX per week
    
    // Tapering thresholds (50% of 10B supply)
    const TAPERING_THRESHOLD: u64 = 5_000_000_000_000_000_000;  // 5B LUX

    // Error codes
    const E_INSUFFICIENT_STAKE: u64 = 0;
    const E_INVALID_TIER: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_LOCK_ACTIVE: u64 = 3;
    const E_COOLDOWN_ACTIVE: u64 = 4;
    const E_NO_REWARDS: u64 = 5;
    const E_STAKE_EXISTS: u64 = 6;
    const E_INSUFFICIENT_BALANCE: u64 = 7;
    const E_INVALID_AMOUNT: u64 = 8;
    const E_PAUSED: u64 = 9;

    // Shared object for staking pool - Added 'store' ability
    public struct StakePool has key, store {
        id: UID,
        total_staked: u64,
        reward_pool: Balance<TOKEN_MANAGEMENT>, // Fixed type
        admin: address,
        tier_aprs: vector<u64>,  // APRs in basis points [tier1, tier2, tier3]
        positions: Table<address, ID>,  // User address -> StakePosition ID
        paused: bool,
        total_rewards_distributed: u64,
    }

    // Owned object per user
    public struct StakePosition has key, store {
        id: UID,
        owner: address,
        amount: u64,
        tier: u64,
        stake_timestamp: u64,
        lock_end_timestamp: u64,
        cooldown_end_timestamp: u64,
        unclaimed_rewards: u64,
        last_claim_timestamp: u64,
        reputation_multiplier: u64,  // In basis points (10000 = 1x)
        total_claimed: u64,
    }

    // Events for transparency
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
        tier: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct ClaimEvent has copy, drop {
        user: address,
        amount: u64,
        tier: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct UpgradeEvent has copy, drop {
        user: address,
        old_tier: u64,
        new_tier: u64,
        additional_amount: u64,
        timestamp: u64,
        position_id: ID,
    }

    public struct RewardTaperingEvent has copy, drop {
        old_aprs: vector<u64>,
        new_aprs: vector<u64>,
        total_staked: u64,
        timestamp: u64,
    }

    // Initialize staking pool
    fun init(_witness: STAKING, ctx: &mut TxContext) {
        let pool = StakePool {
            id: object::new(ctx),
            total_staked: 0,
            reward_pool: balance::zero<TOKEN_MANAGEMENT>(), // Fixed type
            admin: tx_context::sender(ctx),
            tier_aprs: vector[1000, 800, 600],  // 10%, 8%, 6% APR initially
            positions: table::new<address, ID>(ctx),
            paused: false,
            total_rewards_distributed: 0,
        };
        transfer::public_share_object(pool);
    }

    // Stake tokens with reputation multiplier support
    public entry fun stake(
        pool: &mut StakePool,
        tokens: Coin<TOKEN_MANAGEMENT>, // Fixed type
        tier: u64,
        reputation_multiplier: u64,  // From social interactions (basis points)
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let amount = coin::value(&tokens);
        
        assert!(!pool.paused, E_PAUSED);
        assert!(tier >= 1 && tier <= 3, E_INVALID_TIER);
        assert!(!table::contains(&pool.positions, sender), E_STAKE_EXISTS);
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        // Validate minimum stake for tier
        let min_stake = get_min_stake_for_tier(tier);
        assert!(amount >= min_stake, E_INSUFFICIENT_STAKE);

        // Validate reputation multiplier (between 1x and 2x)
        let valid_multiplier = if (reputation_multiplier < BASIS_POINTS) BASIS_POINTS 
                             else if (reputation_multiplier > 2 * BASIS_POINTS) 2 * BASIS_POINTS 
                             else reputation_multiplier;

        // Transfer tokens to staking pool
        let stake_balance = coin::into_balance(tokens);
        assert!(balance::value(&stake_balance) >= amount, E_INSUFFICIENT_BALANCE);
        balance::join(&mut pool.reward_pool, stake_balance);

        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        
        // Create new stake position
        let position = StakePosition {
            id: object::new(ctx),
            owner: sender,
            amount,
            tier,
            stake_timestamp: current_timestamp,
            lock_end_timestamp: current_timestamp + LOCK_PERIOD,
            cooldown_end_timestamp: 0,
            unclaimed_rewards: 0,
            last_claim_timestamp: current_timestamp,
            reputation_multiplier: valid_multiplier,
            total_claimed: 0,
        };
        
        let position_id = object::id(&position);
        pool.total_staked = pool.total_staked + amount;
        table::add(&mut pool.positions, sender, position_id);
        
        // Check for reward tapering
        check_and_apply_tapering(pool, clock);
        
        transfer::transfer(position, sender);

        event::emit(StakeEvent { 
            user: sender, 
            amount, 
            tier, 
            timestamp: current_timestamp,
            position_id,
        });
    }

    // Unstake tokens with cooldown mechanism
    public entry fun unstake(
        pool: &mut StakePool,
        position: &mut StakePosition,
        _clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(!pool.paused, E_PAUSED);
        
        let current_timestamp = clock::timestamp_ms(_clock) / 1000;
        assert!(current_timestamp >= position.lock_end_timestamp, E_LOCK_ACTIVE);

        // First call starts cooldown
        if (position.cooldown_end_timestamp == 0) {
            position.cooldown_end_timestamp = current_timestamp + COOLDOWN_PERIOD;
            return
        };
        
        // Second call after cooldown completes unstaking
        assert!(current_timestamp >= position.cooldown_end_timestamp, E_COOLDOWN_ACTIVE);

        let amount = position.amount;
        let tier = position.tier;
        let position_id = object::id(position);
        
        // Claim any pending rewards first
        if (position.unclaimed_rewards > 0) {
            claim_rewards_internal(pool, position, current_timestamp, ctx);
        };

        // Transfer tokens back to user
        let unstake_balance = balance::split(&mut pool.reward_pool, amount);
        let unstake_coin = coin::from_balance(unstake_balance, ctx);
        transfer::public_transfer(unstake_coin, sender);
        
        // Update pool state
        pool.total_staked = pool.total_staked - amount;
        table::remove(&mut pool.positions, sender);
        
        // Reset position for potential re-staking
        position.amount = 0;
        position.cooldown_end_timestamp = 0;

        event::emit(UnstakeEvent { 
            user: sender, 
            amount, 
            tier,
            timestamp: current_timestamp,
            position_id,
        });
    }

    // Claim rewards with time-based calculation
    public entry fun claim_rewards(
        pool: &mut StakePool,
        position: &mut StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(!pool.paused, E_PAUSED);
        assert!(position.amount > 0, E_INVALID_AMOUNT);

        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        claim_rewards_internal(pool, position, current_timestamp, ctx);
    }

    // Internal reward claiming logic
    fun claim_rewards_internal(
        pool: &mut StakePool,
        position: &mut StakePosition,
        current_timestamp: u64,
        _ctx: &mut TxContext
    ) {
        let time_elapsed = current_timestamp - position.last_claim_timestamp;
        if (time_elapsed == 0) return;

        let base_apr = *vector::borrow(&pool.tier_aprs, position.tier - 1);
        let effective_apr = (base_apr * position.reputation_multiplier) / BASIS_POINTS;
        
        // Calculate reward: (amount * effective_apr * time_elapsed) / (BASIS_POINTS * SECONDS_PER_YEAR)
        let calculated_reward = (position.amount * effective_apr * time_elapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        
        // Apply weekly caps
        let max_weekly_reward = get_max_weekly_reward_for_tier(position.tier);
        let weeks_elapsed = time_elapsed / 604800; // seconds in a week
        let capped_reward = if (calculated_reward > max_weekly_reward * weeks_elapsed) {
            max_weekly_reward * weeks_elapsed
        } else {
            calculated_reward
        };

        position.unclaimed_rewards = position.unclaimed_rewards + capped_reward;
        
        if (position.unclaimed_rewards > 0) {
            assert!(balance::value(&pool.reward_pool) >= position.unclaimed_rewards, E_INSUFFICIENT_BALANCE);
            
            let reward_balance = balance::split(&mut pool.reward_pool, position.unclaimed_rewards);
            let reward_coin = coin::from_balance(reward_balance, _ctx);
            transfer::public_transfer(reward_coin, position.owner);
            
            pool.total_rewards_distributed = pool.total_rewards_distributed + position.unclaimed_rewards;
            position.total_claimed = position.total_claimed + position.unclaimed_rewards;
            
            event::emit(ClaimEvent { 
                user: position.owner, 
                amount: position.unclaimed_rewards, 
                tier: position.tier,
                timestamp: current_timestamp,
                position_id: object::id(position),
            });
            
            position.unclaimed_rewards = 0;
        };
        
        position.last_claim_timestamp = current_timestamp;
    }

    // Upgrade tier by adding tokens
    public entry fun upgrade_tier(
        pool: &mut StakePool,
        position: &mut StakePosition,
        tokens: Coin<TOKEN_MANAGEMENT>, // Fixed type
        new_tier: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(!pool.paused, E_PAUSED);
        assert!(new_tier > position.tier && new_tier <= 3, E_INVALID_TIER);

        let min_stake = get_min_stake_for_tier(new_tier);
        assert!(position.amount < min_stake, E_INSUFFICIENT_STAKE);
        
        let additional_amount = min_stake - position.amount;
        let tokens_balance = coin::into_balance(tokens);
        assert!(balance::value(&tokens_balance) >= additional_amount, E_INSUFFICIENT_BALANCE);

        // Claim pending rewards first
        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        claim_rewards_internal(pool, position, current_timestamp, ctx);

        // Add tokens to pool
        balance::join(&mut pool.reward_pool, tokens_balance);
        
        // Update position and pool
        let old_tier = position.tier;
        pool.total_staked = pool.total_staked + additional_amount;
        position.amount = position.amount + additional_amount;
        position.tier = new_tier;
        position.last_claim_timestamp = current_timestamp;

        // Check for reward tapering
        check_and_apply_tapering(pool, clock);

        event::emit(UpgradeEvent { 
            user: sender, 
            old_tier, 
            new_tier, 
            additional_amount,
            timestamp: current_timestamp,
            position_id: object::id(position),
        });
    }

    // Update reputation multiplier (called by social interaction module)
    public entry fun update_reputation_multiplier(
        position: &mut StakePosition,
        new_multiplier: u64,
        ctx: &mut TxContext
    ) {
        // This should be called by the social interaction module
        // For now, we'll allow the owner to update it
        assert!(position.owner == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Ensure multiplier is between 1x and 2x
        let valid_multiplier = if (new_multiplier < BASIS_POINTS) BASIS_POINTS 
                             else if (new_multiplier > 2 * BASIS_POINTS) 2 * BASIS_POINTS 
                             else new_multiplier;
        
        position.reputation_multiplier = valid_multiplier;
    }

    // Admin function to pause/unpause staking
    public entry fun toggle_pause(pool: &mut StakePool, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        pool.paused = !pool.paused;
    }

    // Admin function to add rewards to pool
    public entry fun add_rewards(
        pool: &mut StakePool,
        reward_tokens: Coin<TOKEN_MANAGEMENT>, // Fixed type
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        let reward_balance = coin::into_balance(reward_tokens);
        balance::join(&mut pool.reward_pool, reward_balance);
    }

    // Reward tapering logic
    fun check_and_apply_tapering(pool: &mut StakePool, _clock: &Clock) {
        if (pool.total_staked > TAPERING_THRESHOLD) {
            let reduction_factor = calculate_tapering_factor(pool.total_staked);
            let old_aprs = pool.tier_aprs;
            
            // Apply reduction to all tiers
            let mut new_aprs = vector::empty<u64>();
            let mut i = 0;
            while (i < vector::length(&old_aprs)) {
                let old_apr = *vector::borrow(&old_aprs, i);
                let new_apr = (old_apr * reduction_factor) / BASIS_POINTS;
                vector::push_back(&mut new_aprs, new_apr);
                i = i + 1;
            };
            
            pool.tier_aprs = new_aprs;
            
            event::emit(RewardTaperingEvent {
                old_aprs,
                new_aprs,
                total_staked: pool.total_staked,
                timestamp: clock::timestamp_ms(_clock) / 1000,
            });
        }
    }

    // Calculate tapering factor based on total staked
    fun calculate_tapering_factor(total_staked: u64): u64 {
        // Linear reduction: 100% at threshold, 50% at 2x threshold
        if (total_staked <= TAPERING_THRESHOLD) {
            BASIS_POINTS // 100%
        } else if (total_staked >= 2 * TAPERING_THRESHOLD) {
            BASIS_POINTS / 2 // 50%
        } else {
            // Linear interpolation between 100% and 50%
            let excess = total_staked - TAPERING_THRESHOLD;
            let reduction = (excess * BASIS_POINTS / 2) / TAPERING_THRESHOLD;
            BASIS_POINTS - reduction
        }
    }

    // Emergency withdrawal (with penalty)
    public entry fun emergency_unstake(
        pool: &mut StakePool,
        position: &mut StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(position.owner == sender, E_UNAUTHORIZED);
        assert!(position.amount > 0, E_INVALID_AMOUNT);

        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        let amount = position.amount;
        let penalty_rate = if (current_timestamp < position.lock_end_timestamp) 1000 else 500; // 10% or 5%
        let penalty = (amount * penalty_rate) / BASIS_POINTS;
        let net_amount = amount - penalty;

        // Transfer net amount to user
        let unstake_balance = balance::split(&mut pool.reward_pool, net_amount);
        let unstake_coin = coin::from_balance(unstake_balance, ctx);
        transfer::public_transfer(unstake_coin, sender);

        // Penalty stays in reward pool
        pool.total_staked = pool.total_staked - amount;
        table::remove(&mut pool.positions, sender);
        position.amount = 0;

        event::emit(UnstakeEvent { 
            user: sender, 
            amount: net_amount, 
            tier: position.tier,
            timestamp: current_timestamp,
            position_id: object::id(position),
        });
    }

    // Batch staking for gas efficiency
    public entry fun batch_stake(
        pool: &mut StakePool,
        tokens: Coin<TOKEN_MANAGEMENT>, // Fixed type
        amounts: vector<u64>,
        tiers: vector<u64>,
        recipients: vector<address>,
        reputation_multipliers: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == pool.admin, E_UNAUTHORIZED);
        assert!(vector::length(&amounts) == vector::length(&tiers), E_INVALID_AMOUNT);
        assert!(vector::length(&amounts) == vector::length(&recipients), E_INVALID_AMOUNT);
        assert!(vector::length(&amounts) == vector::length(&reputation_multipliers), E_INVALID_AMOUNT);
        assert!(vector::length(&amounts) <= 10, E_INVALID_AMOUNT); // Limit batch size

        let mut tokens_balance = coin::into_balance(tokens);
        let mut i = 0;
        
        while (i < vector::length(&amounts)) {
            let amount = *vector::borrow(&amounts, i);
            let tier = *vector::borrow(&tiers, i);
            let recipient = *vector::borrow(&recipients, i);
            let rep_multiplier = *vector::borrow(&reputation_multipliers, i);
            
            // Create position for recipient
            let current_timestamp = clock::timestamp_ms(clock) / 1000;
            let stake_balance = balance::split(&mut tokens_balance, amount);
            balance::join(&mut pool.reward_pool, stake_balance);

            let position = StakePosition {
                id: object::new(ctx),
                owner: recipient,
                amount,
                tier,
                stake_timestamp: current_timestamp,
                lock_end_timestamp: current_timestamp + LOCK_PERIOD,
                cooldown_end_timestamp: 0,
                unclaimed_rewards: 0,
                last_claim_timestamp: current_timestamp,
                reputation_multiplier: rep_multiplier,
                total_claimed: 0,
            };
            
            let position_id = object::id(&position);
            pool.total_staked = pool.total_staked + amount;
            table::add(&mut pool.positions, recipient, position_id);
            
            transfer::transfer(position, recipient);

            event::emit(StakeEvent { 
                user: recipient, 
                amount, 
                tier, 
                timestamp: current_timestamp,
                position_id,
            });
            
            i = i + 1;
        };
        
        // Handle remaining balance
        if (balance::value(&tokens_balance) > 0) {
            let remaining_coin = coin::from_balance(tokens_balance, ctx);
            transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
        } else {
            balance::destroy_zero(tokens_balance);
        };
        
        check_and_apply_tapering(pool, clock);
    }

    // Helper functions
    fun get_min_stake_for_tier(tier: u64): u64 {
        if (tier == 1) MIN_STAKE_TIER_1
        else if (tier == 2) MIN_STAKE_TIER_2
        else MIN_STAKE_TIER_3
    }

    fun get_max_weekly_reward_for_tier(tier: u64): u64 {
        if (tier == 1) MAX_WEEKLY_REWARDS_TIER_1
        else if (tier == 2) MAX_WEEKLY_REWARDS_TIER_2
        else MAX_WEEKLY_REWARDS_TIER_3
    }

    // View functions
    public fun view_position(position: &StakePosition): (u64, u64, u64, u64, u64, u64, u64) {
        (
            position.amount, 
            position.tier, 
            position.lock_end_timestamp, 
            position.cooldown_end_timestamp,
            position.unclaimed_rewards,
            position.reputation_multiplier,
            position.total_claimed
        )
    }

    public fun view_pool(pool: &StakePool): (u64, u64, vector<u64>, bool, u64) {
        (
            pool.total_staked, 
            balance::value(&pool.reward_pool),
            pool.tier_aprs,
            pool.paused,
            pool.total_rewards_distributed
        )
    }

    public fun calculate_pending_rewards(
        pool: &StakePool,
        position: &StakePosition,
        current_timestamp: u64
    ): u64 {
        if (position.amount == 0) return 0;
        
        let time_elapsed = current_timestamp - position.last_claim_timestamp;
        let base_apr = *vector::borrow(&pool.tier_aprs, position.tier - 1);
        let effective_apr = (base_apr * position.reputation_multiplier) / BASIS_POINTS;
        
        let calculated_reward = (position.amount * effective_apr * time_elapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        let max_weekly_reward = get_max_weekly_reward_for_tier(position.tier);
        let weeks_elapsed = time_elapsed / 604800;
        
        if (calculated_reward > max_weekly_reward * weeks_elapsed) {
            max_weekly_reward * weeks_elapsed
        } else {
            calculated_reward
        }
    }

    public fun get_tier_requirements(): (u64, u64, u64) {
        (MIN_STAKE_TIER_1, MIN_STAKE_TIER_2, MIN_STAKE_TIER_3)
    }

    public fun is_position_locked(position: &StakePosition, current_timestamp: u64): bool {
        current_timestamp < position.lock_end_timestamp
    }

    public fun is_cooldown_active(position: &StakePosition, current_timestamp: u64): bool {
        position.cooldown_end_timestamp > 0 && current_timestamp < position.cooldown_end_timestamp
    }
}
