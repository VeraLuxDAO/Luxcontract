module veralux::multisig {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::vector;
    use std::option;

    const TIMELOCK_PERIOD: u64 = 259_200_000; // 72 hours in milliseconds
    const E_UNAUTHORIZED: u64 = 0;
    const E_ACTION_NOT_FOUND: u64 = 1;
    const E_ALREADY_CONFIRMED: u64 = 2;
    const E_NOT_READY: u64 = 3;

    public struct MultisigConfig has key, store {
        id: UID,
        authorities: vector<address>,
        required_confirmations: u64,
        actions: Table<u64, Action>,
        next_action_id: u64,
    }

    public struct Action has store {
        action_type: vector<u8>,
        action_data: vector<u8>,
        confirmations: vector<address>,
        ready_timestamp: option::Option<u64>,
    }

    fun init(ctx: &mut TxContext) {
        let config = MultisigConfig {
            id: object::new(ctx),
            authorities: vector[@Authority1, @Authority2, @Authority3, @Authority4, @Authority5],
            required_confirmations: 2,
            actions: table::new(ctx),
            next_action_id: 0,
        };
        transfer::share_object(config);
    }

    public fun propose_action(
        config: &mut MultisigConfig,
        action_type: vector<u8>,
        action_data: vector<u8>,
        ctx: &mut TxContext
    ): u64 {
        assert!(vector::contains(&config.authorities, &tx_context::sender(ctx)), E_UNAUTHORIZED);
        let action_id = config.next_action_id;
        config.next_action_id = action_id + 1;
        let action = Action {
            action_type,
            action_data,
            confirmations: vector::empty(),
            ready_timestamp: option::none(),
        };
        table::add(&mut config.actions, action_id, action);
        action_id
    }

    public entry fun confirm_action(
        config: &mut MultisigConfig,
        action_id: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(vector::contains(&config.authorities, &sender), E_UNAUTHORIZED);
        let action = table::borrow_mut(&mut config.actions, action_id);
        assert!(!vector::contains(&action.confirmations, &sender), E_ALREADY_CONFIRMED);
        vector::push_back(&mut action.confirmations, sender);
        if (vector::length(&action.confirmations) >= config.required_confirmations) {
            action.ready_timestamp = option::some(clock::timestamp_ms(clock) + TIMELOCK_PERIOD);
        }
    }

    public fun is_action_ready(config: &MultisigConfig, action_id: u64, clock: &Clock): bool {
        if (!table::contains(&config.actions, action_id)) return false;
        let action = table::borrow(&config.actions, action_id);
        if (option::is_none(&action.ready_timestamp)) return false;
        let ready_time = option::borrow(&action.ready_timestamp);
        clock::timestamp_ms(clock) >= *ready_time
    }

    public fun get_action_details(config: &MultisigConfig, action_id: u64): (vector<u8>, vector<u8>, option::Option<u64>) {
        let action = table::borrow(&config.actions, action_id);
        (action.action_type, action.action_data, action.ready_timestamp)
    }

    public fun remove_action(config: &mut MultisigConfig, action_id: u64) {
        table::remove(&mut config.actions, action_id);
    }
}