module fortunex_addr::lucky_mint {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_framework::randomness;
    use aptos_framework::event;
    use aptos_framework::account;

    /// Error codes
    const ERR_EXCEED_ROUND_MAX: u64 = 1;
    const ERR_ROUND_NOT_INITIALIZED: u64 = 2;
    const ERR_COOLDOWN_NOT_FINISHED: u64 = 3;
    const ERR_INSUFFICIENT_MINT_FEE: u64 = 4;

    /// Constants
    const ROUND_MAX_SUPPLY: u64 = 10000;
    const ROUND_INTERVAL: u64 = 600; // 10 minutes
    const MIN_PROBABILITY: u8 = 1;
    const MAX_PROBABILITY: u8 = 100;
    const MINT_COOLDOWN: u64 = 300; // 5 minutes cooldown
    const JACKPOT_THRESHOLD: u8 = 95; // Trigger jackpot above 95%
    const COMBO_THRESHOLD: u8 = 80; // Increase combo above 80%
    const MAX_COMBO_MULTIPLIER: u64 = 5; // Maximum combo multiplier
    const MINT_FEE: u64 = 100; // Base mint fee (in APT minimum units)

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Store round information
    struct RoundInfo has key {
        round_start_time: u64,
        remaining_supply: u64,
        jackpot_pool: u64,
        total_mints: u64,
        lucky_number: u8,
    }

    /// User information
    struct UserInfo has key {
        last_mint_time: u64,
        total_mints: u64,
        best_probability: u8,
        current_combo: u64,
        best_combo: u64,
        achievement_badges: vector<String>,
    }

    /// Mint event
    struct MintEvent has drop, store {
        user: address,
        probability: u8,
        amount: u64,
        is_jackpot: bool,
        combo: u64,
        timestamp: u64,
    }

    /// Event handles
    struct EventHandles has key {
        mint_events: event::EventHandle<MintEvent>,
    }

    fun init_module(sender: &signer) {
        let fa_object = 
        let constructor_ref = fungible_asset::create_metadata(
            sender,
            string::utf8(b"Lucky Token"),
            string::utf8(b"LUCKY"),
            8,
            false,
            false,
            false,
            false,
            false,
        );

        let object_signer = object::generate_signer(&constructor_ref);
        move_to(&object_signer, RoundInfo {
            round_start_time: timestamp::now_seconds(),
            remaining_supply: ROUND_MAX_SUPPLY,
            jackpot_pool: 0,
            total_mints: 0,
            lucky_number: (randomness::u8_range(1, 101) as u8),
        });

        move_to(&object_signer, EventHandles {
            mint_events: account::new_event_handle(&object_signer),
        });
    }

    fun init_user_info(user: &signer) {
        if (!exists<UserInfo>(signer::address_of(user))) {
            move_to(user, UserInfo {
                last_mint_time: 0,
                total_mints: 0,
                best_probability: 0,
                current_combo: 0,
                best_combo: 0,
                achievement_badges: vector::empty(),
            });
        };
    }

    #[view]
    public fun get_round_info(metadata: Object<Metadata>): (u64, u64, u64, u64, u8) acquires RoundInfo {
        let round_info = borrow_global<RoundInfo>(object::object_address(&metadata));
        (
            round_info.round_start_time,
            round_info.remaining_supply,
            round_info.jackpot_pool,
            round_info.total_mints,
            round_info.lucky_number
        )
    }

    #[view]
    public fun get_user_info(user: address): (u64, u64, u8, u64, u64, vector<String>) acquires UserInfo {
        let user_info = borrow_global<UserInfo>(user);
        (
            user_info.last_mint_time,
            user_info.total_mints,
            user_info.best_probability,
            user_info.current_combo,
            user_info.best_combo,
            user_info.achievement_badges
        )
    }

    fun check_and_grant_achievements(user_info: &mut UserInfo, probability: u8) {
        if (probability == 100 && !vector::contains(&user_info.achievement_badges, &string::utf8(b"Perfect Roll"))) {
            vector::push_back(&mut user_info.achievement_badges, string::utf8(b"Perfect Roll"));
        };
        
        if (user_info.total_mints == 100 && !vector::contains(&user_info.achievement_badges, &string::utf8(b"Veteran Minter"))) {
            vector::push_back(&mut user_info.achievement_badges, string::utf8(b"Veteran Minter"));
        };

        if (user_info.current_combo >= 5 && !vector::contains(&user_info.achievement_badges, &string::utf8(b"Combo Master"))) {
            vector::push_back(&mut user_info.achievement_badges, string::utf8(b"Combo Master"));
        };
    }

    #[randomness]
    entry fun mint(
        sender: &signer,
        metadata: Object<Metadata>,
    ) acquires RoundInfo, UserInfo, EventHandles {
        let sender_addr = signer::address_of(sender);
        
        init_user_info(sender);
        
        if (!fungible_asset::store_exists(sender_addr, metadata)) {
            fungible_asset::create_store(sender, metadata);
        };

        let user_info = borrow_global_mut<UserInfo>(sender_addr);
        assert!(
            timestamp::now_seconds() >= user_info.last_mint_time + MINT_COOLDOWN,
            ERR_COOLDOWN_NOT_FINISHED
        );

        let random_probability = randomness::u8_range(MIN_PROBABILITY, MAX_PROBABILITY + 1);
        let round_info = borrow_global_mut<RoundInfo>(object::object_address(&metadata));
        
        let base_amount = (ROUND_MAX_SUPPLY * (random_probability as u64)) / 100;
        let combo_multiplier = if (random_probability >= COMBO_THRESHOLD) {
            user_info.current_combo = user_info.current_combo + 1;
            std::math::min(user_info.current_combo, MAX_COMBO_MULTIPLIER)
        } else {
            user_info.current_combo = 0;
            1
        };
        
        let final_amount = base_amount * combo_multiplier;
        
        user_info.last_mint_time = timestamp::now_seconds();
        user_info.total_mints = user_info.total_mints + 1;
        if (random_probability > user_info.best_probability) {
            user_info.best_probability = random_probability;
        };
        if (user_info.current_combo > user_info.best_combo) {
            user_info.best_combo = user_info.current_combo;
        };

        let is_jackpot = random_probability >= JACKPOT_THRESHOLD;
        if (is_jackpot) {
            final_amount = final_amount + round_info.jackpot_pool;
            round_info.jackpot_pool = 0;
        } else {
            let jackpot_contribution = final_amount / 10;
            round_info.jackpot_pool = round_info.jackpot_pool + jackpot_contribution;
            final_amount = final_amount - jackpot_contribution;
        };

        if (random_probability == round_info.lucky_number) {
            final_amount = final_amount * 2;
        };

        assert!(final_amount <= round_info.remaining_supply, ERR_EXCEED_ROUND_MAX);
        round_info.remaining_supply = round_info.remaining_supply - final_amount;
        round_info.total_mints = round_info.total_mints + 1;

        check_and_grant_achievements(user_info, random_probability);

        let fa = fungible_asset::mint(metadata, final_amount);
        fungible_asset::deposit(sender_addr, fa);

        let handles = borrow_global_mut<EventHandles>(object::object_address(&metadata));
        event::emit_event(
            &mut handles.mint_events,
            MintEvent {
                user: sender_addr,
                probability: random_probability,
                amount: final_amount,
                is_jackpot: is_jackpot,
                combo: user_info.current_combo,
                timestamp: timestamp::now_seconds(),
            },
        );
    }
}
