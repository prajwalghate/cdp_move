module cdp::cdpContract {
    #[test_only]
    friend cdp::cdpContract_tests;

    use supra_framework::supra_coin::SupraCoin;
    use std::signer;
    use std::string;
    use supra_framework::coin::{Self, BurnCapability, FreezeCapability, MintCapability};

    // Error codes
    const ERR_BELOW_MINIMUM_DEBT: u64 = 1;
    const ERR_ALREADY_INITIALIZED: u64 = 2;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 3;
    const ERR_COIN_NOT_INITIALIZED: u64 = 4;

    struct ORECoin { value: u64 }

    struct ConfigParams has key {
        minimum_debt: u64,
        mcr: u64,
        borrow_rate: u64,
        liquidation_reserve: u64,
        liquidation_threshold: u64,
    }

    struct TroveManager has key {
        ore_mint_cap: MintCapability<ORECoin>,
        ore_burn_cap: BurnCapability<ORECoin>,
        ore_freeze_cap: FreezeCapability<ORECoin>,
        total_collateral: u64,
        total_debt: u64,
    }

    

    public fun initialize(admin: &signer) {
        assert!(!exists<ConfigParams>(signer::address_of(admin)), ERR_ALREADY_INITIALIZED);

        // Initialize ORE coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<ORECoin>(
            admin,
            string::utf8(b"ORE Coin"),
            string::utf8(b"ORE"),
            8, // decimals
            true // monitor_supply
        );

        // Set default parameters
        move_to(admin, ConfigParams {
            minimum_debt: 2 * 100000000, // 2000 USD in base units
            mcr: 11000, // 110%
            borrow_rate: 500, // 5% annual rate
            liquidation_reserve: 200 * 100000000, // 200 USD in base units
            liquidation_threshold: 13000, // 130%
        });

        move_to(admin, TroveManager {
            ore_mint_cap: mint_cap,
            ore_burn_cap: burn_cap,
            ore_freeze_cap: freeze_cap,
            total_collateral: 0,
            total_debt: 0,
        });
    }

    #[test_only]
    public fun get_config_params(addr: address): (u64, u64, u64, u64, u64) acquires ConfigParams {
        let config = borrow_global<ConfigParams>(addr);
        (config.minimum_debt, config.mcr, config.borrow_rate, config.liquidation_reserve, config.liquidation_threshold)
    }

    public fun open_trove(user: &signer, supra_amount: u64, ore_amount: u64) acquires ConfigParams, TroveManager {
        let user_addr = signer::address_of(user);
        
        assert!(coin::is_coin_initialized<SupraCoin>(), ERR_COIN_NOT_INITIALIZED);
        assert!(coin::is_coin_initialized<ORECoin>(), ERR_COIN_NOT_INITIALIZED);

        let config = borrow_global<ConfigParams>(@cdp);

        // Check minimum debt
        assert!(ore_amount >= config.minimum_debt, ERR_BELOW_MINIMUM_DEBT);

        // Calculate collateral ratio
        let supra_value = supra_amount * get_supra_price() / 100000000; // Adjust for decimals
        let collateral_ratio = (supra_value * 10000) / ore_amount; // Multiply by 10000 for percentage precision

        // Check if collateral ratio meets minimum requirement
        assert!(collateral_ratio >= config.mcr, ERR_INSUFFICIENT_COLLATERAL);

        // Calculate borrow fee
        let borrow_fee = (ore_amount * config.borrow_rate) / 10000;
        let total_debt = ore_amount + borrow_fee;

        // Transfer SUPRA from user to contract
        coin::transfer<SupraCoin>(user, @cdp, supra_amount);

        // Mint ORE tokens to user
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        
        let ore_coins = coin::mint(ore_amount, &vault_manager.ore_mint_cap);
        coin::deposit(user_addr, ore_coins);

        // Update total stats
        vault_manager.total_collateral = vault_manager.total_collateral + supra_amount;
        vault_manager.total_debt = vault_manager.total_debt + total_debt;
    }

    fun get_supra_price(): u64 {
         100000000
    }

    public fun get_trove_info(addr: address): (u64, u64) acquires TroveManager {
         let vault_manager = borrow_global<TroveManager>(addr);
         (vault_manager.total_collateral, vault_manager.total_debt)
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
         let admin = get_admin_account();
         let admin_addr = signer::address_of(&admin);
         
         // Initialize the contract 
         cdpContract::initialize(&admin);

         // Verify ConfigParams values
         let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold) = cdpContract::get_config_params(admin_addr);
         assert!(min_debt == 2 * 100000000, 0);
         assert!(mcr == 11000, 1);
         assert!(borrow_rate == 500, 2);
         assert!(liq_reserve == 200 * 100000000, 3);
         assert!(liq_threshold == 13000, 4);

         // Verify ORE coin initialization
         assert!(coin::is_coin_initialized<ORECoin>(), 5);
         assert!(coin::name<ORECoin>() == string::utf8(b"ORE Coin"), 6);
         assert!(coin::symbol<ORECoin>() == string::utf8(b"ORE"), 7);
         assert!(coin::decimals<ORECoin>() == 8, 8);
     }

     #[test]
     #[expected_failure(abort_code = cdpContract::ERR_ALREADY_INITIALIZED)]
     fun test_double_initialization() {
         let admin = get_admin_account();
         
         // First initialization should succeed 
         cdpContract::initialize(&admin); 
         
         // Second initialization should fail 
         cdpContract::initialize(&admin); 
     }

     #[test]
     fun test_get_config_params() {
         let admin = get_admin_account();
         let admin_addr = signer::address_of(&admin);
         
         // Initialize the contract 
         cdpContract::initialize(&admin); 

         // Get config params 
         let (min_debt, mcr, borrow_rate, liq_reserve, liq_threshold) = cdpContract::get_config_params(admin_addr);

         // Print values 
         std::debug::print(&min_debt); 
         std::debug::print(&mcr); 
         std::debug::print(&borrow_rate); 
         std::debug::print(&liq_reserve); 
         std::debug::print(&liq_threshold); 

         // Verify expected values 
         assert!(min_debt == 2 * 100000000, 0); 
         assert!(mcr == 11000, 1); 
         assert!(borrow_rate == 500, 2); 
         assert!(liq_reserve == 200 * 100000000, 3); 
         assert!(liq_threshold == 13000, 4); 
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
        coin::register<ORECoin>(&user);
        // Setup initial SUPRA balance for user
        let supra_amount = 1000 * 100000000; // 1000 SUPRA
        // Mint and deposit SUPRA to user
        let coins = coin::mint(supra_amount, &mint_cap);
        coin::deposit(user_addr, coins);
        // Open trove with 1000 SUPRA collateral and borrow 500 ORE
        let collateral = 1000 * 100000000; // 1000 SUPRA
        let borrow_amount = 500 * 100000000; // 500 ORE
        cdpContract::open_trove(&user, collateral, borrow_amount);
        // Calculate expected total debt including borrow fee
        let (_, _, borrow_rate, _, _) = cdpContract::get_config_params(@cdp);
        let borrow_fee = (borrow_amount * borrow_rate) / 10000; // 5% fee
        let total_debt = borrow_amount + borrow_fee;
        // Verify user received ORE coins (they receive the borrowed amount without the fee)
        assert!(coin::balance<ORECoin>(user_addr) == borrow_amount, 0);
        // Verify collateral was transferred
        assert!(coin::balance<SupraCoin>(user_addr) == supra_amount - collateral, 1);

        // Verify trove exists and has correct values
        let (trove_collateral, trove_debt) = cdpContract::get_trove_info(@cdp);
        assert!(trove_collateral == collateral, 2);
        assert!(trove_debt == total_debt, 3); // Compare with total_debt including fee
        // Clean up capabilities
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }
}