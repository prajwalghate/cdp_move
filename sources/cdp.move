module cdp::cdpContract {
    #[test_only]
    friend cdp::cdpContract_tests;

    use supra_framework::supra_coin::SupraCoin;
    use std::signer;
    use std::string;
    use aptos_std::table::{Self, Table};
    use supra_framework::coin::{Self, BurnCapability, FreezeCapability, MintCapability};
    use supra_framework::account;


    // Error codes
    const ERR_BELOW_MINIMUM_DEBT: u64 = 1;
    const ERR_ALREADY_INITIALIZED: u64 = 2;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 3;
    const ERR_COIN_NOT_INITIALIZED: u64 = 4;
    const ERR_NO_TROVE_EXISTS: u64 = 5;
    const ERR_INSUFFICIENT_COLLATERAL_BALANCE: u64 = 6;
    const ERR_INSUFFICIENT_DEBT_BALANCE: u64 = 7;

    struct ORECoin has store { value: u64 }

    struct ConfigParams has key {
        minimum_debt: u64,//20 ore
        mcr: u64,//125
        borrow_rate: u64,//2%
        liquidation_reserve: u64,//2 ore
        liquidation_threshold: u64,//110
        //liquidation penalty
        //
        //
    }

    struct TroveManager has key {
        ore_mint_cap: MintCapability<ORECoin>,
        ore_burn_cap: BurnCapability<ORECoin>,
        ore_freeze_cap: FreezeCapability<ORECoin>,
        total_collateral: u64,
        total_debt: u64,
    }

    struct UserPosition has store, drop, copy {
        total_debt: u64,
        total_collateral: u64,
        is_active: bool,
    }

    struct UserPositionsTable has key {
        positions: Table<address, UserPosition>,
    }

    struct SignerCapability has key {
        cap: account::SignerCapability
    }



    

    public entry fun initialize(admin: &signer) {
        assert!(!exists<ConfigParams>(signer::address_of(admin)), ERR_ALREADY_INITIALIZED);
        // Initialize ORE coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<ORECoin>(
            admin,
            string::utf8(b"ORE Coin"),
            string::utf8(b"ORE"),
            8,
            true
        );

        let (resource_signer, signer_cap) = account::create_resource_account(admin, b"cdp_pool");
        coin::register<SupraCoin>(&resource_signer);  // Register resource account for SupraCoin
        move_to(admin, SignerCapability { cap: signer_cap });   

        coin::register<SupraCoin>(admin);
        coin::register<ORECoin>(admin);

        // Set default parameters
        move_to(admin, ConfigParams {
            minimum_debt: 20 * 100000000, // 20 in base units
            mcr: 12500, // 110%
            borrow_rate: 200, // 5% annual rate
            liquidation_reserve: 2 * 100000000, // 2  in base units
            liquidation_threshold: 11000, // 130%
        });

        move_to(admin, TroveManager {
            ore_mint_cap: mint_cap,
            ore_burn_cap: burn_cap,
            ore_freeze_cap: freeze_cap,
            total_collateral: 0,
            total_debt: 0,
        });

        move_to(admin, UserPositionsTable {
            positions: table::new(),
        });
    }


    // public entry fun mint_ore(user: &signer, amount: u64) acquires TroveManager {
        
    //     coin::register<ORECoin>(user);
        
    //     let user_addr = signer::address_of(user);
    //     // Mint ORE tokens to user
    //     let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        
    //     let ore_coins = coin::mint(amount, &vault_manager.ore_mint_cap);
    //     coin::deposit(user_addr, ore_coins);

    //     coin::transfer<SupraCoin>(user, @cdp, 100000000);
        
    // }

    

   public entry fun open_trove(
        user: &signer,
        supra_deposit: u64,
        ore_mint: u64
    ) acquires ConfigParams, TroveManager, UserPositionsTable, SignerCapability {
        let user_addr = signer::address_of(user);
        
        // Verify minimum debt
        let config = borrow_global<ConfigParams>(@cdp);
        assert!(ore_mint >= config.minimum_debt, ERR_BELOW_MINIMUM_DEBT);
        
        // Calculate total debt including borrow fee
        let borrow_fee = (ore_mint * config.borrow_rate) / 10000;
        let total_debt = ore_mint + borrow_fee;
        
        // Verify MCR condition
        let total_collateral_value = supra_deposit * get_supra_price() / 100000000;
        let collateral_ratio = (total_collateral_value * 10000) / total_debt;
        assert!(collateral_ratio >= config.mcr, ERR_INSUFFICIENT_COLLATERAL);
        
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resource_addr = signer::address_of(&resource_signer);
        // Transfer SUPRA to contract
        coin::transfer<SupraCoin>(user, resource_addr, supra_deposit);
        
        // Register user for ORECoin if needed and mint ORE
        if (!coin::is_account_registered<ORECoin>(user_addr)) {
            coin::register<ORECoin>(user);
        };
        
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let ore_coins = coin::mint(ore_mint, &vault_manager.ore_mint_cap);
        coin::deposit(user_addr, ore_coins);
        
        // Update total stats
        vault_manager.total_collateral = vault_manager.total_collateral + supra_deposit;
        vault_manager.total_debt = vault_manager.total_debt + total_debt;
        
        // Create user position
        update_user_position(user_addr, total_debt, supra_deposit, true)
    }

    public entry fun deposit_or_mint(
            user: &signer,
            supra_deposit: u64,
            ore_mint: u64
    ) acquires ConfigParams, TroveManager, UserPositionsTable {
        let user_addr = signer::address_of(user);
        
        // Get user's current position
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions_table.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions_table.positions, user_addr);
        
        // Calculate new totals
        let new_collateral = position.total_collateral + supra_deposit;
        let borrow_fee = (ore_mint * borrow_global<ConfigParams>(@cdp).borrow_rate) / 10000;
        let new_debt = position.total_debt + ore_mint + borrow_fee;
        
        // Verify MCR condition
        let total_collateral_value = new_collateral * get_supra_price() / 100000000;
        let collateral_ratio = (total_collateral_value * 10000) / new_debt;
        assert!(collateral_ratio >= borrow_global<ConfigParams>(@cdp).mcr, ERR_INSUFFICIENT_COLLATERAL);
        
        // Handle SUPRA deposit
        if (supra_deposit > 0) {
            coin::transfer<SupraCoin>(user, @cdp, supra_deposit);
        };
        
        // Handle ORE minting
        if (ore_mint > 0) {
            if (!coin::is_account_registered<ORECoin>(user_addr)) {
                coin::register<ORECoin>(user)
            };
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let ore_coins = coin::mint(ore_mint, &vault_manager.ore_mint_cap);
            coin::deposit(user_addr, ore_coins);
            
            // Update total stats
            vault_manager.total_collateral = vault_manager.total_collateral + supra_deposit;
            vault_manager.total_debt = vault_manager.total_debt + ore_mint + borrow_fee;
        };
        
        // Update user position
        update_user_position(user_addr, new_debt, new_collateral, true)
    }


    public entry fun repay_or_withdraw(
            user: &signer,
            supra_withdraw: u64,
            ore_repay: u64
    ) acquires ConfigParams, TroveManager, UserPositionsTable, SignerCapability {
        let user_addr = signer::address_of(user);
        
        // Get user's current position
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions_table.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions_table.positions, user_addr);
        
        // Calculate new totals
        assert!(position.total_collateral >= supra_withdraw, ERR_INSUFFICIENT_COLLATERAL_BALANCE);
        assert!(position.total_debt >= ore_repay, ERR_INSUFFICIENT_DEBT_BALANCE);
        
        let new_collateral = position.total_collateral - supra_withdraw;
        let new_debt = position.total_debt - ore_repay;
        
        // If there's remaining debt, verify MCR condition
        if (new_debt > 0) {
            let total_collateral_value = new_collateral * get_supra_price() / 100000000;
            let collateral_ratio = (total_collateral_value * 10000) / new_debt;
            assert!(collateral_ratio >= borrow_global<ConfigParams>(@cdp).mcr, ERR_INSUFFICIENT_COLLATERAL);
        };
        
        // Handle SUPRA withdrawal
        if (supra_withdraw > 0) {
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);
            
            // Get resource account address
            let resource_addr = signer::address_of(&resource_signer);
            
            // Debug print balances before transfer
            std::debug::print(&coin::balance<SupraCoin>(resource_addr));
            
            coin::transfer<SupraCoin>(&resource_signer, user_addr, supra_withdraw);
            vault_manager.total_collateral = vault_manager.total_collateral - supra_withdraw;
        };
        
        // Handle ORE repayment
        if (ore_repay > 0) {
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let ore_coins = coin::withdraw<ORECoin>(user, ore_repay);
            coin::burn(ore_coins, &vault_manager.ore_burn_cap);
            vault_manager.total_debt = vault_manager.total_debt - ore_repay;
        };
        
        // Update user position
        update_user_position(user_addr, new_debt, new_collateral, new_debt > 0)
    }


    public entry fun close_trove(user: &signer) acquires TroveManager, UserPositionsTable, SignerCapability 
    {
        let user_addr = signer::address_of(user);
        
        // Get user's current position
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions_table.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions_table.positions, user_addr);
        let user_balance = coin::balance<ORECoin>(user_addr);
        std::debug::print(&b"User ORE Balance:");
        std::debug::print(&user_balance);
        std::debug::print(&b"Total Debt:");
        std::debug::print(&position.total_debt);
        // Ensure user has enough ORE to repay debt
        assert!(coin::balance<ORECoin>(user_addr) >= position.total_debt, ERR_INSUFFICIENT_DEBT_BALANCE);
        
        // Handle ORE repayment
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let ore_coins = coin::withdraw<ORECoin>(user, position.total_debt);
        coin::burn(ore_coins, &vault_manager.ore_burn_cap);
        vault_manager.total_debt = vault_manager.total_debt - position.total_debt;
        
        // Return collateral to user
        let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        coin::transfer<SupraCoin>(&resource_signer, user_addr, position.total_collateral);
        vault_manager.total_collateral = vault_manager.total_collateral - position.total_collateral;
        
        // Update user position (set to inactive with zero debt and collateral)
        update_user_position(user_addr, 0, 0, false)
    }





    fun update_user_position(
        user_addr: address, 
        debt: u64, 
        collateral: u64, 
        active: bool
    ) acquires UserPositionsTable {
        let positions_table = borrow_global_mut<UserPositionsTable>(@cdp);
        
        let new_position = UserPosition {
            total_debt: debt,
            total_collateral: collateral,
            is_active: active,
        };

        if (table::contains(&positions_table.positions, user_addr)) {
            *table::borrow_mut(&mut positions_table.positions, user_addr) = new_position;
        } else {
            table::add(&mut positions_table.positions, user_addr, new_position);
        }
    }


    #[view]
    public fun get_config(): (u64, u64, u64, u64, u64) acquires ConfigParams {
        let config = borrow_global<ConfigParams>(@cdp);
        (config.minimum_debt, config.mcr, config.borrow_rate, config.liquidation_reserve, config.liquidation_threshold)
    }

    #[view]
    fun get_supra_price(): u64 {
         100000000
    }

    #[view]
    public  fun get_trove_info(addr: address): (u64, u64) acquires TroveManager {
         let vault_manager = borrow_global<TroveManager>(addr);
         (vault_manager.total_collateral, vault_manager.total_debt)
    }

    #[view]
    public fun get_user_position(user_addr: address): (u64, u64, bool) acquires UserPositionsTable {
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        
        if (table::contains(&positions_table.positions, user_addr)) {
            let position = table::borrow(&positions_table.positions, user_addr);
            (position.total_debt, position.total_collateral, position.is_active)
        } else {
            (0, 0, false) // Return default values if user not found
        }
    }

    #[test_only]
    public fun mint_ore_for_test(addr: address, amount: u64) acquires TroveManager {
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let ore_coins = coin::mint(amount, &vault_manager.ore_mint_cap);
        coin::deposit(addr, ore_coins);
    }
}

#[test_only]
module cdp::cdpContract_tests {
    use std::signer;
    use std::string;
    use supra_framework::coin;
    use supra_framework::account;
    use cdp::cdpContract;
    use cdp::cdpContract::ORECoin;
    use supra_framework::supra_coin::SupraCoin;

    fun get_admin_account(): signer {
        account::create_account_for_test(@cdp)
    }

     #[test]
     fun test_successful_initialization() {
        let framework = account::create_account_for_test(@0x1);

        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
         let admin = get_admin_account();
        //  let admin_addr = signer::address_of(&admin);
        //  supra_framework::supra_coin::initialize_for_test(&framework);
         // Initialize the contract 
         cdpContract::initialize(&admin);

         // Verify ConfigParams values
         let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold) = cdpContract::get_config();
         assert!(min_debt == 20 * 100000000, 0);
         assert!(mcr == 12500, 1);
         assert!(borrow_rate == 200, 2);
         assert!(liq_reserve == 2 * 100000000, 3);
         assert!(liq_threshold == 11000, 4);

         // Verify ORE coin initialization
         assert!(coin::is_coin_initialized<ORECoin>(), 5);
         assert!(coin::name<ORECoin>() == string::utf8(b"ORE Coin"), 6);
         assert!(coin::symbol<ORECoin>() == string::utf8(b"ORE"), 7);
         assert!(coin::decimals<ORECoin>() == 8, 8);
         coin::destroy_mint_cap(mint_cap);
         coin::destroy_burn_cap(burn_cap);   
     }

     #[test]
     #[expected_failure(abort_code = cdpContract::ERR_ALREADY_INITIALIZED)]
     fun test_double_initialization() {
        let framework = account::create_account_for_test(@0x1);

        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
         let admin = get_admin_account();
         
         // First initialization should succeed 
         cdpContract::initialize(&admin); 
         
         // Second initialization should fail 
         cdpContract::initialize(&admin);
         coin::destroy_mint_cap(mint_cap);
         coin::destroy_burn_cap(burn_cap); 
     }

     #[test]
     fun test_get_config() {
        let framework = account::create_account_for_test(@0x1);

        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
         let admin = get_admin_account();
         let admin_addr = signer::address_of(&admin);
         
         // Initialize the contract 
         cdpContract::initialize(&admin); 

         // Get config params 
         let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold) = cdpContract::get_config();

         // Print values 
         std::debug::print(&min_debt); 
         std::debug::print(&mcr); 
         std::debug::print(&borrow_rate); 
         std::debug::print(&liq_reserve); 
         std::debug::print(&liq_threshold); 

         // Verify expected values 
         assert!(min_debt == 20 * 100000000, 0); 
         assert!(mcr == 12500, 1); 
         assert!(borrow_rate == 200, 2); 
         assert!(liq_reserve == 2 * 100000000, 3); 
         assert!(liq_threshold == 11000, 4); 
         coin::destroy_mint_cap(mint_cap);
         coin::destroy_burn_cap(burn_cap);
     }

    #[test]
    fun test_open_trove() {
        // Create supra framework account for proper initialization
        let framework = account::create_account_for_test(@0x1);
        
        // Create admin and user accounts
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        // First initialize SupraCoin using the framework account
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 
        // Initialize CDP contract (this will initialize ORECoin)
        cdpContract::initialize(&admin);
        // Register accounts for coins
        coin::register<SupraCoin>(&admin); // Register admin (CDP contract) for SupraCoin
        coin::register<SupraCoin>(&user);
        // coin::register<ORECoin>(&user);
        // Setup initial SUPRA balance for user
        let supra_amount = 1000 * 100000000; // 1000 SUPRA
        // Mint and deposit SUPRA to user
        let coins = coin::mint(supra_amount, &mint_cap);
        coin::deposit(user_addr, coins);
        // Open trove with 1000 SUPRA collateral and borrow 500 ORE
        let collateral = 1000 * 100000000; // 1000 SUPRA
        let borrow_amount = 400 * 100000000; // 500 ORE
        cdpContract::open_trove(&user, collateral, borrow_amount);
        // Calculate expected total debt including borrow fee
        let (_, _, borrow_rate, _, _) = cdpContract::get_config();
        let borrow_fee = (borrow_amount * borrow_rate) / 10000; // 5% fee
        let total_debt = borrow_amount + borrow_fee;
        // Verify user received ORE coins (they receive the borrowed amount without the fee)
        assert!(coin::balance<ORECoin>(user_addr) == borrow_amount, 0);
        // Verify collateral was transferred
        assert!(coin::balance<SupraCoin>(user_addr) == supra_amount - collateral, 1);

        let balance = coin::balance<ORECoin>(user_addr);
        std::debug::print(&balance);

        // Verify trove exists and has correct values
        let (trove_collateral, trove_debt) = cdpContract::get_trove_info(@cdp);
        assert!(trove_collateral == collateral, 2);
        assert!(trove_debt == total_debt, 3); // Compare with total_debt including fee
        // Clean up capabilities
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

        #[test]
    fun test_open_trove_user_position() {
        // Create supra framework account for proper initialization
        let framework = account::create_account_for_test(@0x1);
        
        // Create admin and user accounts
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);

        // First initialize SupraCoin using the framework account
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework); 

        // Initialize CDP contract (this will initialize ORECoin)
        cdpContract::initialize(&admin);

        // Register accounts for coins
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);

        // Setup initial SUPRA balance for user
        let supra_amount = 1000 * 100000000; // 1000 SUPRA
        // Mint and deposit SUPRA to user
        let coins = coin::mint(supra_amount, &mint_cap);
        coin::deposit(user_addr, coins);

        // Open trove with 1000 SUPRA collateral and borrow 400 ORE
        let collateral = 1000 * 100000000; // 1000 SUPRA
        let borrow_amount = 400 * 100000000; // 400 ORE
        cdpContract::open_trove(&user, collateral, borrow_amount);

        // Calculate expected total debt including borrow fee
        let (_, _, borrow_rate, _, _) = cdpContract::get_config();
        let borrow_fee = (borrow_amount * borrow_rate) / 10000; // 5% fee
        let expected_total_debt = borrow_amount + borrow_fee;

        // Get user position and verify it's correctly set
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        
        // Debug prints
        std::debug::print(&actual_debt);
        std::debug::print(&actual_collateral);
        std::debug::print(&is_active);

        // Assert user position values
        assert!(actual_debt == expected_total_debt, 0); // Verify debt amount
        assert!(actual_collateral == collateral, 1);    // Verify collateral amount
        assert!(is_active == true, 2);                  // Verify position is active

        // Clean up capabilities
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_deposit_or_mint() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        // Setup initial balances and open trove
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        
        // Initial deposit of 1000 SUPRA and mint 400 ORE
        let initial_supra = 2000 * 100000000; // 2000 SUPRA for testing
        let initial_deposit = 1000 * 100000000; // 1000 SUPRA
        let initial_borrow = 400 * 100000000; // 400 ORE
        
        // Give user initial SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Test deposit_or_mint
        let additional_deposit = 200 * 100000000; // 200 more SUPRA
        let additional_mint = 100 * 100000000; // 100 more ORE
        
        cdpContract::deposit_or_mint(&user, additional_deposit, additional_mint);
        
        // Verify updated position
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        let expected_collateral = initial_deposit + additional_deposit;
        
        // Calculate expected debt including fees
        let initial_fee = (initial_borrow * 200) / 10000; // 5% fee
        let additional_fee = (additional_mint * 200) / 10000;
        let expected_debt = initial_borrow + initial_fee + additional_mint + additional_fee;
        
        assert!(actual_collateral == expected_collateral, 0);
        assert!(actual_debt == expected_debt, 1);
        assert!(is_active == true, 2);
        
        // Verify balances
        assert!(coin::balance<ORECoin>(user_addr) == initial_borrow + additional_mint, 3);
        assert!(coin::balance<SupraCoin>(user_addr) == initial_supra - expected_collateral, 4);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_repay_or_withdraw() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        // Register accounts for coins
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Initial deposit of 1000 SUPRA and mint 400 ORE
        let initial_supra = 2000 * 100000000; // 2000 SUPRA
        let initial_deposit = 1000 * 100000000; // 1000 SUPRA
        let initial_borrow = 400 * 100000000; // 400 ORE
        
        // Give user initial SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Debug print initial SUPRA balance
        std::debug::print(&coin::balance<SupraCoin>(user_addr));
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Debug print balances after opening trove
        std::debug::print(&coin::balance<SupraCoin>(user_addr));
        std::debug::print(&coin::balance<SupraCoin>(@cdp));
        std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Test repay_or_withdraw
        let withdraw_amount = 200 * 100000000; // 200 SUPRA
        let repay_amount = 100 * 100000000; // 100 ORE
        
        cdpContract::repay_or_withdraw(&user, withdraw_amount, repay_amount);
        
        // Debug print final balances
        std::debug::print(&coin::balance<SupraCoin>(user_addr));
        std::debug::print(&coin::balance<SupraCoin>(@cdp));
        std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Verify updated position
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        let expected_collateral = initial_deposit - withdraw_amount;
        
        // Calculate expected debt including initial fee
        let initial_fee = (initial_borrow * 200) / 10000; // 5% fee
        let expected_debt = initial_borrow + initial_fee - repay_amount;
        
        assert!(actual_collateral == expected_collateral, 0);
        assert!(actual_debt == expected_debt, 1);
        assert!(is_active == true, 2);
        
        // Verify balances
        assert!(coin::balance<ORECoin>(user_addr) == initial_borrow - repay_amount, 3);
        assert!(coin::balance<SupraCoin>(user_addr) == initial_supra - expected_collateral, 4);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }






    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_deposit_or_mint_fails_mcr() {
        // Similar setup as above
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        
        // Initial setup
        let initial_supra = 2000 * 100000000;
        let initial_deposit = 1000 * 100000000;
        let initial_borrow = 400 * 100000000;
        
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Try to mint too much ORE without enough collateral
        let additional_mint = 900 * 100000000; // This should fail MCR check
        cdpContract::deposit_or_mint(&user, 0, additional_mint);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_repay_or_withdraw_fails_mcr() {
        // Similar setup as above
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        
        // Initial setup
        let initial_supra = 2000 * 100000000;
        let initial_deposit = 1000 * 100000000;
        let initial_borrow = 400 * 100000000;
        
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Try to withdraw too much collateral
        let withdraw_amount = 800 * 100000000; // This should fail MCR check
        cdpContract::repay_or_withdraw(&user, withdraw_amount, 0);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

  #[test]
    fun test_close_trove() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        // Register accounts for coins
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Initial deposit of 1000 SUPRA and mint 400 ORE
        let initial_supra = 2000 * 100000000; // 2000 SUPRA
        let initial_deposit = 1000 * 100000000; // 1000 SUPRA
        let initial_borrow = 400 * 100000000; // 400 ORE
        
        // Give user initial SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Calculate total debt including fee
        let (_, _, borrow_rate, _, _) = cdpContract::get_config();
        let borrow_fee = (initial_borrow * borrow_rate) / 10000; // 5% fee
        
        // Mint additional ORE to cover the fee
        cdpContract::mint_ore_for_test(user_addr, borrow_fee);
        
        // Close trove
        cdpContract::close_trove(&user);
        
        // Verify trove is closed and balances are correct
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        assert!(actual_debt == 0, 0);
        assert!(actual_collateral == 0, 1);
        assert!(is_active == false, 2);
        
        // Verify user received back their collateral
        assert!(coin::balance<SupraCoin>(user_addr) == initial_supra, 3);
        assert!(coin::balance<ORECoin>(user_addr) == 0, 4); // All ORE should be burned
        
        // Verify global state
        let (trove_collateral, trove_debt) = cdpContract::get_trove_info(@cdp);
        assert!(trove_collateral == 0, 5);
        assert!(trove_debt == 0, 6);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    // #[test]
    // fun test_initialize_coin_store() {
    //     let admin = get_admin_account();
    //     let user = account::create_account_for_test(@0x456);
        
    //     // Ensure the user account is not registered for SupraCoin initially
    //     assert!(!coin::is_account_registered<SupraCoin>(signer::address_of(&user)), 0);
        
    //     // Initialize the coin store for the user
    //     cdpContract::initialize_coin_store(&admin);
        
    //     // Verify that the user account is now registered for SupraCoin
    //     assert!(coin::is_account_registered<SupraCoin>(signer::address_of(&admin)), 1);
    // }

    // #[test]
    // fun test_mint_ore() {
    //     let admin = get_admin_account();
    //     let user = account::create_account_for_test(@0x456);
        
    //     // Initialize the contract 
    //     cdpContract::initialize(&admin);
        
    //     // Register user for ORECoin
    //     // coin::register<ORECoin>(&user);
        
    //     // Mint ORE coins to user
    //     let mint_amount = 1000 * 100000000; // 1000 ORE
    //     cdpContract::mint_ore(&user, mint_amount);
        
    //     // Debug: Check balance before assertion
    //     let user_addr = signer::address_of(&user);
    //     let balance = coin::balance<ORECoin>(user_addr);
    //     std::debug::print(&balance); // Print the balance to debug

    //     // Verify user received ORE coins
    //     // assert!(balance == mint_amount, 0);
    // }
}