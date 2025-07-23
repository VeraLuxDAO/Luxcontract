# VeraLux Token & Staking Testing Guide

## Pre-Deployment Setup

### 1. Address Replacements Required

Before deployment, replace these placeholder addresses in both modules:

**Token Management Module:**
```move
// Replace these addresses in TokenConfig initialization
@0xStakingContract -> [ACTUAL_STAKING_CONTRACT_ADDRESS]
@0xTreasuryAddress -> [ACTUAL_TREASURY_ADDRESS]
@0xAuthority1 -> [MULTISIG_AUTHORITY_1]
@0xAuthority2 -> [MULTISIG_AUTHORITY_2]
@0xAuthority3 -> [MULTISIG_AUTHORITY_3]
@0xAuthority4 -> [MULTISIG_AUTHORITY_4]
@0xAuthority5 -> [MULTISIG_AUTHORITY_5]
@0xGovernanceAddress -> [GOVERNANCE_CONTRACT_ADDRESS]
@0xLiquidityAddress -> [LIQUIDITY_POOL_ADDRESS]
@0xBurnAddress -> [BURN_ADDRESS]

// Initial distribution addresses
@0xPrivateSale -> [PRIVATE_SALE_ADDRESS]
@0xPresale -> [PRESALE_ADDRESS]
@0xLiquidityPool -> [LIQUIDITY_POOL_ADDRESS]
@0xAirdrop -> [AIRDROP_ADDRESS]
@0xStakingRewards -> [STAKING_REWARDS_ADDRESS]
@0xTeam -> [TEAM_ADDRESS]
@0xMarketing -> [MARKETING_ADDRESS]
```

### 2. Deployment Order

1. **Deploy Token Management** first
2. **Deploy Staking Module** second
3. **Update Token Management** with staking contract address
4. **Call initial_distribution** to mint tokens
5. **Add rewards** to staking pool

## Testing Framework Setup

### Sui CLI Commands

```bash
# Initialize Sui project
sui move new veralux_token
cd veralux_token

# Create module files
mkdir sources
# Copy token_management.move and staking.move to sources/

# Build project
sui move build

# Deploy to testnet
sui client publish --gas-budget 50000000

# Get object IDs after deployment
sui client objects --address [YOUR_ADDRESS]
```

## Unit Testing Scenarios

### Token Management Tests

#### 1. Initialization Test
```bash
# Test: Verify initial supply and configuration
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function view_config \
  --args [TOKEN_CONFIG_OBJECT_ID] \
  --gas-budget 1000000

# Expected: tax_rate=400, pause_flag=false, total_supply=100B
```

#### 2. Tax-Exempt Transfer Test
```bash
# Test: Staking contract transfers without tax
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function privileged_transfer \
  --args [TOKEN_CONFIG_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 1000000000000 \
  --gas-budget 5000000

# Expected: No tax deducted, TransferEvent with taxed=false
```

#### 3. Regular Transfer with Tax Test
```bash
# Test: Regular user transfer with 4% tax
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [TOKEN_CONFIG_ID] [USER_REGISTRY_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 1000000000000 \
  --gas-budget 5000000

# Expected: 96% to recipient, 4% distributed to governance/liquidity/burn/staking
```

#### 4. Daily Transfer Limit Test
```bash
# Test: Attempt transfer > 0.1% daily limit
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [TOKEN_CONFIG_ID] [USER_REGISTRY_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 200000000000000000 \
  --gas-budget 5000000

# Expected: Should fail with E_SUPPLY_EXCEEDED
```

#### 5. Cooldown Test
```bash
# Test: Two transfers in same epoch
# First transfer (should succeed)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [TOKEN_CONFIG_ID] [USER_REGISTRY_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 1000000000000 \
  --gas-budget 5000000

# Second transfer immediately (should fail)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [TOKEN_CONFIG_ID] [USER_REGISTRY_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 1000000000000 \
  --gas-budget 5000000

# Expected: Second call fails with E_COOLDOWN_ACTIVE
```

#### 6. Governance Tax Update Test
```bash
# Test: Propose tax rate change (requires multisig authority)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function propose_tax_update \
  --args [TOKEN_CONFIG_ID] 300 "[2000,3000,2500,2500]" \
  --gas-budget 5000000

# Vote for proposal (need 3 authorities)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function vote_for_tax_update \
  --args [TOKEN_CONFIG_ID] \
  --gas-budget 2000000

# Execute after timelock (2160 epochs)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function execute_tax_update \
  --args [TOKEN_CONFIG_ID] \
  --gas-budget 5000000
```

#### 7. Pause Functionality Test
```bash
# Test: Propose pause
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function propose_pause \
  --args [TOKEN_CONFIG_ID] true \
  --gas-budget 5000000

# Vote and execute pause
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function vote_for_pause \
  --args [TOKEN_CONFIG_ID] \
  --gas-budget 2000000

# Try transfer while paused (should fail)
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [TOKEN_CONFIG_ID] [USER_REGISTRY_ID] [COIN_OBJECT_ID] [RECIPIENT_ADDRESS] 1000000000000 \
  --gas-budget 5000000

# Expected: Fails with E_PAUSED
```

### Staking Module Tests

#### 1. Staking Pool Initialization
```bash
# Test: Initialize staking pool with reward tokens
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function init \
  --args [REWARD_COIN_OBJECT_ID] \
  --gas-budget 5000000

# Verify pool creation
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function view_pool \
  --args [STAKE_POOL_ID] \
  --gas-budget 1000000
```

#### 2. Tier 1 Staking Test
```bash
# Test: Stake minimum for Tier 1 (250K LUX)
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function stake \
  --args [STAKE_POOL_ID] [COIN_OBJECT_ID] 250000000000000 1 10000 [CLOCK_ID] \
  --gas-budget 10000000

# Expected: StakeEvent emitted, position created
```

#### 3. Tier Upgrade Test
```bash
# Test: Upgrade from Tier 1 to Tier 2
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function upgrade_tier \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [COIN_OBJECT_ID] 2 [CLOCK_ID] \
  --gas-budget 10000000

# Expected: Additional 750K LUX staked, tier updated to 2
```

#### 4. Reward Calculation Test
```bash
# Test: Check pending rewards after time passes
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function calculate_pending_rewards \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CURRENT_TIMESTAMP] \
  --gas-budget 2000000

# Expected: Non-zero reward amount based on APR and time
```

#### 5. Reward Claiming Test
```bash
# Test: Claim accumulated rewards
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function claim_rewards \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CLOCK_ID] \
  --gas-budget 10000000

# Expected: ClaimEvent emitted, tokens transferred to user
```

#### 6. Lock Period Test
```bash
# Test: Attempt unstake before lock period ends
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function unstake \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CLOCK_ID] \
  --gas-budget 10000000

# Expected: Should fail with E_LOCK_ACTIVE (first 7 days)
```

#### 7. Cooldown Mechanism Test
```bash
# Test: First unstake call (after lock period)
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function unstake \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CLOCK_ID] \
  --gas-budget 10000000

# Expected: Cooldown initiated, no tokens transferred

# Test: Second unstake call (before cooldown ends)
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function unstake \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CLOCK_ID] \
  --gas-budget 10000000

# Expected: Should fail with E_COOLDOWN_ACTIVE

# Test: Final unstake (after cooldown)
# Wait 7 days, then retry
# Expected: Tokens returned, UnstakeEvent emitted
```

#### 8. Emergency Unstake Test
```bash
# Test: Emergency unstake with penalty
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function emergency_unstake \
  --args [STAKE_POOL_ID] [STAKE_POSITION_ID] [CLOCK_ID] \
  --gas-budget 10000000

# Expected: Tokens returned minus penalty (10% if locked, 5% if unlocked)
```

#### 9. Reward Tapering Test
```bash
# Test: Stake enough to trigger tapering (>5B LUX total)
# Multiple large stakes to reach threshold
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function stake \
  --args [STAKE_POOL_ID] [LARGE_COIN_OBJECT_ID] 3000000000000000000 3 10000 [CLOCK_ID] \
  --gas-budget 20000000

# Expected: RewardTaperingEvent emitted, APRs reduced
```

#### 10. Batch Staking Test
```bash
# Test: Admin batch stake for multiple users
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function batch_stake \
  --args [STAKE_POOL_ID] [COIN_OBJECT_ID] "[250000000000000,1000000000000000]" "[1,2]" "[0xuser1,0xuser2]" "[10000,12000]" [CLOCK_ID] \
  --gas-budget 20000000

# Expected: Multiple StakeEvents, positions created for users
```

## Integration Testing

### 1. End-to-End Transfer + Staking Flow
```bash
# 1. User receives tokens from initial distribution
# 2. User transfers tokens (pays tax)
# 3. Tax goes to staking rewards pool
# 4. User stakes remaining tokens
# 5. User claims rewards from staking
# 6. User unstakes after lock period

# Verify tax distribution reaches staking pool
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function view_pool \
  --args [STAKE_POOL_ID] \
  --gas-budget 1000000
```

### 2. Governance Integration Test
```bash
# 1. Stake tokens to get voting power
# 2. Propose tax rate change
# 3. Vote with multiple authorities
# 4. Execute change after timelock
# 5. Verify new tax rate applied to transfers
```

### 3. Multi-User Scenario Test
```bash
# Simulate 10+ users:
# - Various stake amounts and tiers
# - Different timing for stakes/unstakes
# - Concurrent reward claims
# - Transfer tax distribution
```

## Performance Testing

### Gas Usage Benchmarks
- Token transfer: ~5M gas
- Staking: ~10M gas
- Unstaking: ~10M gas
- Reward claiming: ~8M gas
- Governance voting: ~3M gas

### Load Testing
- Batch operations up to 10 users
- Concurrent staking/unstaking
- Multiple reward claims in single epoch

## Security Testing

### 1. Access Control Tests
- Only authorities can propose governance changes
- Only admin can pause staking
- Only position owner can unstake
- Only privileged addresses exempt from tax

### 2. Economic Attack Tests
- Attempt to stake below minimum
- Try to claim more rewards than available
- Attempt double-spending in transfers
- Gaming daily transfer limits

### 3. Overflow/Underflow Tests
- Maximum supply constraints
- Reward calculation edge cases
- Large number arithmetic

## Monitoring & Events

### Key Events to Monitor
```bash
# Token events
- MintEvent: Initial distribution tracking
- TransferEvent: Tax application verification
- BurnEvent: Deflationary mechanism tracking
- UpdateEvent: Governance changes
- PauseEvent: Emergency controls

# Staking events
- StakeEvent: User engagement tracking
- UnstakeEvent: Liquidity monitoring
- ClaimEvent: Reward distribution tracking
- UpgradeEvent: Tier progression tracking
- RewardTaperingEvent: Economic balancing
```

### Dashboard Metrics
- Total supply vs burned amount
- Tax collection and distribution
- Staking participation rates
- APR changes over time
- Daily active users

## Error Handling Verification

### Expected Error Scenarios
- `E_INSUFFICIENT_BALANCE`: Transfer more than owned
- `E_SUPPLY_EXCEEDED`: Transfer above daily limit
- `E_COOLDOWN_ACTIVE`: Transfer twice in same epoch
- `E_PAUSED`: Transfer when paused
- `E_UNAUTHORIZED`: Non-authority governance action
- `E_LOCK_ACTIVE`: Unstake during lock period
- `E_INSUFFICIENT_STAKE`: Stake below tier minimum

## Post-Deployment Checklist

### 1. Verify Deployments
- [ ] Token config object created
- [ ] User registry object created
- [ ] Staking pool object created
- [ ] All placeholder addresses replaced
- [ ] Initial distribution completed

### 2. Test Core Functions
- [ ] Tax-exempt transfers work
- [ ] Regular transfers apply tax correctly
- [ ] Staking works for all tiers
- [ ] Reward calculations accurate
- [ ] Unstaking cooldown enforced
- [ ] Emergency unstake applies penalty
- [ ] Governance timelock functions
- [ ] Pause mechanism works

### 3. Security Verification
- [ ] Only authorities can vote on governance
- [ ] Transfer limits enforced
- [ ] Cooldown prevents spam
- [ ] Position ownership verified
- [ ] Reward pool has sufficient balance
- [ ] No unauthorized minting possible

### 4. Economic Parameters
- [ ] Tax rate: 4% (400 basis points)
- [ ] Tax allocation: 25% each to governance/liquidity/burn/staking
- [ ] Tier 1 APR: 10% with 250K minimum stake
- [ ] Tier 2 APR: 8% with 1M minimum stake  
- [ ] Tier 3 APR: 6% with 5M minimum stake
- [ ] Tapering threshold: 5B total staked
- [ ] Lock period: 7 days
- [ ] Cooldown period: 7 days

## Production Deployment Guide

### 1. Mainnet Deployment Steps

```bash
# Switch to mainnet
sui client switch --env mainnet

# Verify balance for deployment
sui client balance

# Deploy with sufficient gas
sui client publish --gas-budget 100000000

# Record deployment info
echo "Package ID: [RECORD_HERE]" > deployment.log
echo "Token Config: [RECORD_HERE]" >> deployment.log  
echo "User Registry: [RECORD_HERE]" >> deployment.log
echo "Stake Pool: [RECORD_HERE]" >> deployment.log
```

### 2. Initial Setup Sequence

```bash
# 1. Deploy token management
sui client publish --gas-budget 50000000

# 2. Deploy staking module  
sui client publish --gas-budget 50000000

# 3. Update token config with staking address
sui client call --package [TOKEN_PACKAGE_ID] \
  --module token_management \
  --function update_privileged_addresses \
  --args [TOKEN_CONFIG_ID] [STAKING_CONTRACT_ADDRESS] [TREASURY_ADDRESS] \
  --gas-budget 5000000

# 4. Initialize staking pool with rewards
sui client call --package [STAKING_PACKAGE_ID] \
  --module staking \
  --function init \
  --args [REWARD_COIN_OBJECT_ID] \
  --gas-budget 10000000

# 5. Execute initial token distribution
sui client call --package [TOKEN_PACKAGE_ID] \
  --module token_management \
  --function initial_distribution \
  --args [TOKEN_CONFIG_ID] \
  --gas-budget 20000000
```

### 3. Multisig Setup

```bash
# Create multisig wallet for governance
sui client new-address ed25519 authority1
sui client new-address ed25519 authority2  
sui client new-address ed25519 authority3
sui client new-address ed25519 authority4
sui client new-address ed25519 authority5

# Fund authority addresses
sui client transfer-sui --to [AUTHORITY1] --amount 1000000000
# Repeat for all authorities

# Test multisig governance proposal
# Authority 1 proposes
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function propose_tax_update \
  --args [TOKEN_CONFIG_ID] 350 "[2000,2500,2500,3000]" \
  --gas-budget 5000000

# Authorities 2 & 3 vote  
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function vote_for_tax_update \
  --args [TOKEN_CONFIG_ID] \
  --gas-budget 2000000
```

## Advanced Testing Scenarios

### 1. Stress Testing

```bash
# Create multiple test accounts
for i in {1..20}; do
  sui client new-address ed25519 user$i
done

# Distribute test tokens
for addr in $(sui client addresses); do
  sui client transfer-sui --to $addr --amount 100000000
done

# Concurrent staking test
# Run multiple stake commands simultaneously
seq 1 10 | xargs -I {} -P 10 sui client call --package [PACKAGE_ID] \
  --module staking \
  --function stake \
  --args [STAKE_POOL_ID] [COIN_ID_{}] 250000000000000 1 10000 [CLOCK_ID] \
  --gas-budget 15000000
```

### 2. Economic Simulation

```bash
# Simulate 30-day staking cycle
# Day 1: Initial stakes
# Day 7: Lock period ends
# Day 14: First unstake cooldowns start
# Day 21: Some users unstake, others claim rewards
# Day 30: Mass unstaking event

# Monitor pool metrics throughout
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function view_pool \
  --args [STAKE_POOL_ID] \
  --gas-budget 1000000

# Track reward distribution
sui client events --module staking --struct ClaimEvent
```

### 3. Upgrade Testing

```bash
# Test module upgrade compatibility
# Deploy new version with same structs
sui client publish --upgrade-capability [UPGRADE_CAP_ID] \
  --gas-budget 50000000

# Verify existing positions still work
sui client call --package [NEW_PACKAGE_ID] \
  --module staking \
  --function view_position \
  --args [EXISTING_POSITION_ID] \
  --gas-budget 1000000
```

## Monitoring & Alerting

### 1. Key Metrics to Track

```javascript
// Example monitoring dashboard queries
const metrics = {
  totalSupply: "SELECT sum(amount) FROM mint_events",
  totalBurned: "SELECT sum(amount) FROM burn_events", 
  totalStaked: "SELECT sum(amount) FROM stake_events - sum(amount) FROM unstake_events",
  dailyTransfers: "SELECT count(*) FROM transfer_events WHERE date = today",
  averageAPR: "SELECT avg(tier_apr) FROM reward_tapering_events ORDER BY timestamp DESC LIMIT 1",
  activeStakers: "SELECT count(DISTINCT user) FROM stake_events WHERE position_active = true"
};
```

### 2. Alert Conditions

```yaml
alerts:
  - name: "High Tax Collection"
    condition: "daily_tax_amount > 1000000000000000" # 1M LUX
    action: "notify_team"
    
  - name: "Low Reward Pool"  
    condition: "reward_pool_balance < 100000000000000" # 100K LUX
    action: "add_rewards"
    
  - name: "Mass Unstaking"
    condition: "daily_unstake_amount > total_staked * 0.1" # >10% daily
    action: "emergency_review"
    
  - name: "Governance Proposal"
    condition: "new_proposal_created = true"
    action: "notify_authorities"
```

### 3. Health Checks

```bash
#!/bin/bash
# health_check.sh - Run every hour

# Check if transfers are working
transfer_test=$(sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function transfer \
  --args [CONFIG_ID] [REGISTRY_ID] [TEST_COIN] [TEST_ADDR] 1000000000 \
  --gas-budget 5000000 2>&1)

if [[ $transfer_test == *"error"* ]]; then
  echo "ALERT: Token transfers failing"
  # Send notification
fi

# Check staking pool balance
pool_balance=$(sui client call --package [PACKAGE_ID] \
  --module staking \
  --function view_pool \
  --args [POOL_ID] \
  --gas-budget 1000000 | grep -o '"[0-9]*"' | head -2 | tail -1)

if [ "$pool_balance" -lt "100000000000000" ]; then
  echo "ALERT: Staking reward pool low: $pool_balance"
fi

# Check for pending governance proposals
pending_proposals=$(sui client events --module token_management --struct UpdateEvent --count 10)
echo "Recent governance activity: $pending_proposals"
```

## Troubleshooting Guide

### Common Issues & Solutions

#### 1. Transaction Failures
```bash
# Issue: "Insufficient gas"
# Solution: Increase gas budget
--gas-budget 20000000

# Issue: "Object not found"  
# Solution: Check object ID is correct
sui client object [OBJECT_ID]

# Issue: "Move abort in [ADDRESS]::token_management::transfer: E_COOLDOWN_ACTIVE"
# Solution: Wait for next epoch or use privileged transfer
```

#### 2. Staking Issues
```bash
# Issue: Cannot stake - "E_INSUFFICIENT_STAKE"
# Solution: Check minimum amounts
# Tier 1: 250,000 LUX (250000000000000 with decimals)  
# Tier 2: 1,000,000 LUX (1000000000000000 with decimals)
# Tier 3: 5,000,000 LUX (5000000000000000 with decimals)

# Issue: Cannot claim rewards - "E_NO_REWARDS"
# Solution: Wait for time to pass since last claim
```

#### 3. Governance Issues  
```bash
# Issue: "E_UNAUTHORIZED" when proposing
# Solution: Ensure sender is in authorities list
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function view_config \
  --args [CONFIG_ID] \
  --gas-budget 1000000

# Issue: "E_TIMELOCK_ACTIVE" when executing
# Solution: Wait for timelock period (2160 epochs for tax changes)
```

## Best Practices

### 1. Development
- Always test on devnet/testnet first
- Use consistent gas budgets (add 20% buffer)
- Validate all inputs before calling functions
- Monitor events for debugging
- Keep backups of important object IDs

### 2. Production
- Use multisig for all admin functions
- Set up comprehensive monitoring
- Have emergency pause procedures ready
- Regular security audits
- Document all parameter changes

### 3. User Experience
- Provide clear error messages
- Show pending rewards in UI
- Display lock/cooldown timers
- Explain tax implications
- Guide users through tier requirements

### 4. Economic Management
- Monitor total staked vs threshold
- Track reward pool depletion rate
- Adjust APRs based on participation
- Maintain balanced tax distribution
- Plan for reward pool refills

## Emergency Procedures

### 1. Emergency Pause
```bash
# If critical issue discovered
sui client call --package [PACKAGE_ID] \
  --module token_management \
  --function propose_pause \
  --args [CONFIG_ID] true \
  --gas-budget 5000000

# Get other authorities to vote immediately
# Execute after minimum timelock (720 epochs)
```

### 2. Reward Pool Emergency
```bash
# If staking rewards running low
sui client call --package [PACKAGE_ID] \
  --module staking \
  --function add_rewards \
  --args [POOL_ID] [EMERGENCY_COIN_ID] \
  --gas-budget 10000000
```

### 3. Contract Upgrade
```bash
# If bug found requiring upgrade
sui client upgrade --package [PACKAGE_ID] \
  --upgrade-cap [UPGRADE_CAP_ID] \
  --gas-budget 100000000
```

This comprehensive testing guide covers all aspects of the VeraLux token ecosystem from unit testing to production monitoring. Follow the checklist systematically to ensure a robust, secure deployment.
