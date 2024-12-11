module cdp::cdpContract {
    #[test_only]
    friend cdp::cdpContract_tests;

    use supra_framework::supra_coin::SupraCoin;
    use std::signer;
    use std::string;
    // use std::event;
    use std::fixed_point32::{Self, FixedPoint32};
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
    const ERR_TROVE_ALREADY_ACTIVE: u64 = 8;    
    const FEE_COLLECTOR: address = @0x1e54313f47251c2ef107578da12935f8abe6bee77410e06c804e28d23c156f44; // 
    const LR_COLLECTOR: address = @0x18ffab5e7c45db3f94539686083b03e4c7cae248d8f5754639b190c02f2589f8; //

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

    struct PriceOracle has key {
        price: fixed_point32::FixedPoint32
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
            borrow_rate: 200, // 2% annual rate
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

        // Initialize price oracle with default price
        move_to(admin, PriceOracle {
            price: fixed_point32::create_from_rational(10 * 100000000, 100000000) // Default 10 USD
        });
    }


   public entry fun open_trove(
        user: &signer,
        supra_deposit: u64,
        ore_mint: u64
    ) acquires ConfigParams, TroveManager, UserPositionsTable, SignerCapability, PriceOracle  {
        let user_addr = signer::address_of(user);

        // Check if trove exists and is active
        let positions = borrow_global<UserPositionsTable>(@cdp);
        if (table::contains(&positions.positions, user_addr)) {
            let position = table::borrow(&positions.positions, user_addr);
            assert!(!position.is_active, ERR_TROVE_ALREADY_ACTIVE);
        };
        
        // Get config parameters without borrowing
        let (minimum_debt, _, borrow_rate, liquidation_reserve, _) = get_config();
        assert!(ore_mint >= minimum_debt, ERR_BELOW_MINIMUM_DEBT);
        
        // Calculate total debt including borrow fee and liquidation reserve
        let borrow_fee = (ore_mint * borrow_rate) / 10000;
        let total_debt = ore_mint + borrow_fee + liquidation_reserve;
        
        // Verify MCR condition
        verify_collateral_ratio(supra_deposit, total_debt);
        
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
        
        // Mint requested amount to user
        let ore_coins = coin::mint(ore_mint, &vault_manager.ore_mint_cap);
        coin::deposit(user_addr, ore_coins);
        
        // Mint borrow fee to FEE_COLLECTOR
        let fee_coins = coin::mint(borrow_fee, &vault_manager.ore_mint_cap);
        coin::deposit(FEE_COLLECTOR, fee_coins);
        
        // Mint liquidation reserve to LR_COLLECTOR
        let lr_coins = coin::mint(liquidation_reserve, &vault_manager.ore_mint_cap);
        coin::deposit(LR_COLLECTOR, lr_coins);
        
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
    ) acquires ConfigParams, TroveManager, UserPositionsTable,SignerCapability, PriceOracle  {
        let user_addr = signer::address_of(user);
        assert_trove_active(user_addr);
        // Get user's current position
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions_table.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions_table.positions, user_addr);
        
        // Calculate new totals
        let new_collateral = position.total_collateral + supra_deposit;
        let borrow_fee = (ore_mint * borrow_global<ConfigParams>(@cdp).borrow_rate) / 10000;
        let new_debt = position.total_debt + ore_mint + borrow_fee;
        
        // Verify MCR condition using fixed point math
        verify_collateral_ratio(new_collateral, new_debt);
        
        // Handle SUPRA deposit
        if (supra_deposit > 0) {
            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);
            let resource_addr = signer::address_of(&resource_signer);
            coin::transfer<SupraCoin>(user, resource_addr, supra_deposit);
        };
        
        // Handle ORE minting
        if (ore_mint > 0) {
            if (!coin::is_account_registered<ORECoin>(user_addr)) {
                coin::register<ORECoin>(user)
            };
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let ore_coins = coin::mint(ore_mint, &vault_manager.ore_mint_cap);
            coin::deposit(user_addr, ore_coins);

            // Mint borrow fee to FEE_COLLECTOR
            let fee_coins = coin::mint(borrow_fee, &vault_manager.ore_mint_cap);
            coin::deposit(FEE_COLLECTOR, fee_coins);
            
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
    ) acquires ConfigParams, TroveManager, UserPositionsTable, SignerCapability, PriceOracle  {
        let user_addr = signer::address_of(user);
        assert_trove_active(user_addr);
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
            verify_collateral_ratio(new_collateral, new_debt);
        };
        
        // Handle SUPRA withdrawal
        if (supra_withdraw > 0) {
            let vault_manager = borrow_global_mut<TroveManager>(@cdp);
            let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
            let resource_signer = account::create_signer_with_capability(signer_cap);
            
            // Get resource account address
            let resource_addr = signer::address_of(&resource_signer);
            
            // Debug print balances before transfer
            // std::debug::print(&coin::balance<SupraCoin>(resource_addr));
            
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

    

    public entry fun close_trove(user: &signer) acquires TroveManager, UserPositionsTable, SignerCapability {
        let user_addr = signer::address_of(user);
        assert_trove_active(user_addr);
        // Get user's current position
        let positions_table = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions_table.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions_table.positions, user_addr);
        // let user_balance = coin::balance<ORECoin>(user_addr);
        // Then check if trove is active
        assert!(position.is_active, ERR_NO_TROVE_EXISTS);
        
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

    fun assert_trove_active(user_addr: address) acquires UserPositionsTable {
        let positions = borrow_global<UserPositionsTable>(@cdp);
        assert!(table::contains(&positions.positions, user_addr), ERR_NO_TROVE_EXISTS);
        let position = table::borrow(&positions.positions, user_addr);
        assert!(position.is_active, ERR_NO_TROVE_EXISTS);
    }

    public fun verify_collateral_ratio(collateral: u64, debt: u64) acquires ConfigParams, PriceOracle {
        if (debt > 0) {
            let price = get_supra_price();
            let total_collateral_value = fixed_point32::multiply_u64(collateral, price);
            let ratio_multiplier = fixed_point32::create_from_rational(10000, 1);
            let mcr_check = fixed_point32::multiply_u64(total_collateral_value, ratio_multiplier) / debt;
            
            assert!(mcr_check >= borrow_global<ConfigParams>(@cdp).mcr, ERR_INSUFFICIENT_COLLATERAL);
        }
    }

    public entry fun register_ore_coin(account: &signer) {
        if (!coin::is_account_registered<ORECoin>(signer::address_of(account))) {
            coin::register<ORECoin>(account);
        }
    }


    #[view]
    public fun get_fee_collector(): address {
        FEE_COLLECTOR
    }

    #[view]
    public fun get_lr_collector(): address {
        LR_COLLECTOR
    }


    #[view]
    public fun get_config(): (u64, u64, u64, u64, u64) acquires ConfigParams {
        let config = borrow_global<ConfigParams>(@cdp);
        (config.minimum_debt, config.mcr, config.borrow_rate, config.liquidation_reserve, config.liquidation_threshold)
    }

    #[view]
    public fun get_supra_price(): fixed_point32::FixedPoint32 acquires PriceOracle {
        if (!exists<PriceOracle>(@cdp)) {
            // Return default price of 10 USD if not set
            fixed_point32::create_from_rational(10 * 100000000, 100000000)
        } else {
            *&borrow_global<PriceOracle>(@cdp).price
        }
    }

    #[view]
    public fun get_supra_price_raw(): u64 acquires PriceOracle {
        let price_oracle = borrow_global<PriceOracle>(@cdp);
        fixed_point32::multiply_u64(100000000, price_oracle.price) // Convert back to base units
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

    // #[view]
    // public fun get_user_balances(user_addr: address): (u64, u64) {
    //     (
    //         coin::balance<ORECoin>(user_addr),
    //         coin::balance<SupraCoin>(user_addr)
    //     )
    // }

    // #[view]
    // public fun get_resource_account_balances(): (address, u64) acquires SignerCapability {
    //     let signer_cap = &borrow_global<SignerCapability>(@cdp).cap;
    //     let resource_signer = account::create_signer_with_capability(signer_cap);
    //     let resource_addr = signer::address_of(&resource_signer);
        
    //     (resource_addr, coin::balance<SupraCoin>(resource_addr))
    // }

    #[test_only]
    public fun mint_ore_for_test(addr: address, amount: u64) acquires TroveManager {
        let vault_manager = borrow_global_mut<TroveManager>(@cdp);
        let ore_coins = coin::mint(amount, &vault_manager.ore_mint_cap);
        coin::deposit(addr, ore_coins);
    }

    public entry fun set_price(admin: &signer, new_price: u64) acquires PriceOracle {
        // Only admin can set price
        assert!(signer::address_of(admin) == @cdp, 0); // You might want to add a specific error code
        
        let price = fixed_point32::create_from_rational(new_price, 100000000); // Assuming 8 decimals
        
        if (!exists<PriceOracle>(@cdp)) {
            move_to(admin, PriceOracle { price });
        } else {
            let price_oracle = borrow_global_mut<PriceOracle>(@cdp);
            price_oracle.price = price;
        }
    }
}

#[test_only]
module cdp::cdpContract_tests {
    use std::signer;
    use std::string;
    use std::fixed_point32;
    use supra_framework::coin;
    use supra_framework::account;
    use aptos_std::table;
    use cdp::cdpContract;
    use cdp::cdpContract::ORECoin;
    use supra_framework::supra_coin::SupraCoin;

    fun get_admin_account(): signer {
        account::create_account_for_test(@cdp)
    }

    fun setup_collector_accounts() {
        let fee_collector = account::create_account_for_test(cdpContract::get_fee_collector());
        let lr_collector = account::create_account_for_test(cdpContract::get_lr_collector());
        
        // Register both accounts for ORECoin
        cdpContract::register_ore_coin(&fee_collector);
        cdpContract::register_ore_coin(&lr_collector);
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
         setup_collector_accounts();

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
        //  std::debug::print(&min_debt); 
        //  std::debug::print(&mcr); 
        //  std::debug::print(&borrow_rate); 
        //  std::debug::print(&liq_reserve); 
        //  std::debug::print(&liq_threshold); 

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
        setup_collector_accounts();
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
        // let lr = 2 * 100000000; // 500 ORE

        cdpContract::open_trove(&user, collateral, borrow_amount);
        // Calculate expected total debt including borrow fee
        let (_, _, borrow_rate, liquidation_reserve, _) = cdpContract::get_config();
        let borrow_fee = (borrow_amount * borrow_rate) / 10000; // 5% fee
        let total_debt = borrow_amount + borrow_fee + liquidation_reserve;
        // Verify user received ORE coins (they receive the borrowed amount without the fee)
        assert!(coin::balance<ORECoin>(user_addr) == borrow_amount, 0);
        // Verify collateral was transferred
        assert!(coin::balance<SupraCoin>(user_addr) == supra_amount - collateral, 1);

        let balance = coin::balance<ORECoin>(user_addr);
        // std::debug::print(&balance);

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

        setup_collector_accounts(); 
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
        let (_, _, borrow_rate, liquidation_reserve, _) = cdpContract::get_config();
        let borrow_fee = (borrow_amount * borrow_rate) / 10000; // 5% fee
        let expected_total_debt = borrow_amount + borrow_fee +liquidation_reserve;

        // Get user position and verify it's correctly set
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        
        // Debug prints
        // std::debug::print(&actual_debt);
        // std::debug::print(&actual_collateral);
        // std::debug::print(&is_active);

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
        
        setup_collector_accounts();
        // Setup initial balances and open trove
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        
        // Initial deposit of 1000 SUPRA and mint 400 ORE
        let initial_supra = 2000 * 100000000; // 2000 SUPRA for testing
        let initial_deposit = 1000 * 100000000; // 1000 SUPRA
        let initial_borrow = 400 * 100000000; // 400 ORE
        let liquidation_reserve=2 * 100000000;
        
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
        let expected_debt = initial_borrow + initial_fee + additional_mint + additional_fee + liquidation_reserve;
        
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
        
        setup_collector_accounts();
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
        // std::debug::print(&coin::balance<SupraCoin>(user_addr));
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Debug print balances after opening trove
        // std::debug::print(&coin::balance<SupraCoin>(user_addr));
        // std::debug::print(&coin::balance<SupraCoin>(@cdp));
        // std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Test repay_or_withdraw
        let withdraw_amount = 200 * 100000000; // 200 SUPRA
        let repay_amount = 100 * 100000000; // 100 ORE
        
        cdpContract::repay_or_withdraw(&user, withdraw_amount, repay_amount);
        
        // Debug print final balances
        // std::debug::print(&coin::balance<SupraCoin>(user_addr));
        // std::debug::print(&coin::balance<SupraCoin>(@cdp));
        // std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Verify updated position
        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        let expected_collateral = initial_deposit - withdraw_amount;
        
        // Calculate expected debt including initial fee
        let initial_fee = (initial_borrow * 200) / 10000; // 5% fee
        let liquidation_reserve=2 * 100000000;
        let expected_debt = initial_borrow + initial_fee+liquidation_reserve - repay_amount;
        
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
    fun test_register_ore_coin() {
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        
        cdpContract::initialize(&admin);
        
        // Create test account
        let test_account = account::create_account_for_test(@0x123);
        
        // Verify account is not registered initially
        assert!(!coin::is_account_registered<ORECoin>(signer::address_of(&test_account)), 0);
        
        // Register account
        cdpContract::register_ore_coin(&test_account);
        
        // Verify account is now registered
        assert!(coin::is_account_registered<ORECoin>(signer::address_of(&test_account)), 1);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }






   #[test]
    #[expected_failure(abort_code = cdpContract::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_deposit_or_mint_fails_mcr() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        setup_collector_accounts();
        
        // Setup initial balances
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Initial setup - deposit 100 SUPRA and mint 800 ORE
        // With price of 10 USD per SUPRA:
        // 100 SUPRA = 1000 USD collateral
        // 800 ORE debt requires 1000 USD collateral at 125% MCR
        let initial_supra = 200 * 100000000; // 200 SUPRA
        let initial_deposit = 100 * 100000000; // 100 SUPRA
        let initial_borrow = 800 * 100000000; // 800 ORE - at the MCR limit
        
        // Give user initial SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Try to mint more ORE without adding collateral
        // This should fail as it would put the position below MCR
        cdpContract::deposit_or_mint(&user, 0, 100 * 100000000); // Try to mint 100 more ORE
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_repay_or_withdraw_fails_mcr() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        setup_collector_accounts();
        // Setup initial balances
        coin::register<SupraCoin>(&admin);
        coin::register<SupraCoin>(&user);
        
        // Initial setup - deposit 200 SUPRA and mint 800 ORE
        let initial_supra = 300 * 100000000; // 300 SUPRA
        let initial_deposit = 200 * 100000000; // 200 SUPRA
        let initial_borrow = 800 * 100000000; // 800 ORE
        
        // Give user initial SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Open initial trove
        cdpContract::open_trove(&user, initial_deposit, initial_borrow);
        
        // Try to withdraw too much collateral
        // With price of 10 USD per SUPRA, 200 SUPRA = 2000 USD collateral
        // Trying to withdraw 150 SUPRA would leave only 50 SUPRA (500 USD) backing 800 ORE
        // This would put the ratio well below MCR of 125%
        cdpContract::repay_or_withdraw(&user, 150 * 100000000, 0);
        
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
        
        setup_collector_accounts();
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
        let (_, _, borrow_rate, liquidation_reserve, _) = cdpContract::get_config();
        let borrow_fee = (initial_borrow * borrow_rate) / 10000; // 5% fee
        
        // Mint additional ORE to cover the fee
        cdpContract::mint_ore_for_test(user_addr, borrow_fee+ liquidation_reserve);

        let (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
        assert!(is_active == true,4);
        
        // Close trove
        cdpContract::close_trove(&user);
        
        // Verify trove is closed and balances are correct
        (actual_debt, actual_collateral, is_active) = cdpContract::get_user_position(user_addr);
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

    #[test]
    fun test_get_supra_price() {
        // Get the price using the module's function
        let price = cdpContract::get_supra_price();
        
        // Convert to u64 for easier printing (multiply by 10000 to show decimal places)
        let price_as_u64 = fixed_point32::multiply_u64(10000, price);
        
        // Print raw FixedPoint32 value
        // std::debug::print(&b"Raw FixedPoint32 SUPRA price:");
        // std::debug::print(&price);
        
        // Print human-readable value (should be 10.0000)
        // std::debug::print(&b"SUPRA price in USD (multiplied by 10000 for decimals):");
        // std::debug::print(&price_as_u64);
        
        // Verify price is correct (10 USD)
        let expected_price = fixed_point32::create_from_rational(10 * 100000000, 100000000);
        assert!(price == expected_price, 1);
    }

    #[test]
    fun test_verify_collateral_ratio_valid() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Test cases with valid ratios
        // Case 1: Exactly at MCR (125%)
        // With SUPRA price = 10 USD:
        // 1000 SUPRA = 10000 USD collateral value
        // 8000 ORE debt requires 10000 USD collateral at 125% MCR
        cdpContract::verify_collateral_ratio(1000 * 100000000, 8000 * 100000000);
        
        // Case 2: Well above MCR (200%)
        // 1000 SUPRA = 10000 USD collateral value
        // 5000 ORE debt = 200% collateralization
        cdpContract::verify_collateral_ratio(1000 * 100000000, 5000 * 100000000);
        
        // Case 3: Zero debt (should always pass)
        cdpContract::verify_collateral_ratio(100 * 100000000, 0);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_INSUFFICIENT_COLLATERAL)]
    fun test_verify_collateral_ratio_below_mcr() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Test case with invalid ratio (100%)
        // 1000 SUPRA = 10000 USD collateral value
        // 10000 ORE debt would require 12500 USD collateral at 125% MCR
        cdpContract::verify_collateral_ratio(1000 * 100000000, 10000 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_verify_collateral_ratio_edge_cases() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Case 1: Zero collateral with zero debt (should pass)
        cdpContract::verify_collateral_ratio(0, 0);
        
        // Case 2: Very large collateral amount
        let large_collateral = 1000000 * 100000000; // 1 million SUPRA
        let large_debt = 8000000 * 100000000; // 8 million ORE (maintains 125% ratio)
        cdpContract::verify_collateral_ratio(large_collateral, large_debt);
        
        // Case 3: Minimum viable amounts
        // With SUPRA price = 10 USD:
        // 1 SUPRA = 10 USD collateral value
        // 8 ORE debt requires 10 USD collateral at 125% MCR
        cdpContract::verify_collateral_ratio(1 * 100000000, 8 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_verify_collateral_ratio_calculations() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Get the current MCR from config
        let (_, mcr, _, _, _) = cdpContract::get_config();
        // std::debug::print(&b"Current MCR:");
        // std::debug::print(&mcr); // Should be 12500 (125%)
        
        // Get current SUPRA price
        let price = cdpContract::get_supra_price();
        let price_as_u64 = fixed_point32::multiply_u64(10000, price);
        // std::debug::print(&b"SUPRA price (scaled by 10000):");
        // std::debug::print(&price_as_u64); // Should be 100000 (10.0000 USD)
        
        // Test with exact MCR ratio
        let collateral = 1000 * 100000000; // 1000 SUPRA
        let debt = 8000 * 100000000; // 8000 ORE
        
        // Calculate and print the actual ratio for verification
        let collateral_value = fixed_point32::multiply_u64(collateral, price);
        let ratio_multiplier = fixed_point32::create_from_rational(10000, 1);
        let actual_ratio = fixed_point32::multiply_u64(collateral_value, ratio_multiplier) / debt;
        
        // std::debug::print(&b"Actual ratio:");
        // std::debug::print(&actual_ratio);
        
        // Verify the ratio is valid
        cdpContract::verify_collateral_ratio(collateral, debt);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
        }

    #[test]
    fun test_collector_balances() {
        // Setup initial state
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize coins and contract
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        
        // Setup collector accounts
        setup_collector_accounts();
        
        // Register user for coins
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Give user initial SUPRA
        let initial_supra = 2000 * 100000000; // 2000 SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Test Case 1: Open Trove
        let deposit_amount = 1000 * 100000000; // 1000 SUPRA
        let borrow_amount = 400 * 100000000; // 400 ORE
        
        // Get initial balances
        let fee_collector_initial = coin::balance<ORECoin>(cdpContract::get_fee_collector());
        let lr_collector_initial = coin::balance<ORECoin>(cdpContract::get_lr_collector());
        
        // Open trove
        cdpContract::open_trove(&user, deposit_amount, borrow_amount);
        
        // Calculate expected fees
        let (_, _, borrow_rate, liquidation_reserve, _) = cdpContract::get_config();
        let expected_fee = (borrow_amount * borrow_rate) / 10000;
        
        // Verify FEE_COLLECTOR received the correct fee
        let fee_collector_after = coin::balance<ORECoin>(cdpContract::get_fee_collector());
        assert!(fee_collector_after == fee_collector_initial + expected_fee, 1);
        
        // Verify LR_COLLECTOR received the liquidation reserve
        let lr_collector_after = coin::balance<ORECoin>(cdpContract::get_lr_collector());
        assert!(lr_collector_after == lr_collector_initial + liquidation_reserve, 2);
        
        // Test Case 2: Deposit or Mint (should only affect FEE_COLLECTOR)
        let additional_mint = 200 * 100000000; // 200 ORE
        
        // Store FEE_COLLECTOR balance before additional mint
        let fee_collector_before_mint = fee_collector_after;
        let lr_collector_before_mint = lr_collector_after;
        
        // Perform additional mint
        cdpContract::deposit_or_mint(&user, 0, additional_mint);
        
        // Calculate expected additional fee
        let additional_fee = (additional_mint * borrow_rate) / 10000;
        
        // Verify FEE_COLLECTOR received the additional fee
        let fee_collector_final = coin::balance<ORECoin>(cdpContract::get_fee_collector());
        assert!(fee_collector_final == fee_collector_before_mint + additional_fee, 3);
        
        // Verify LR_COLLECTOR balance didn't change (no additional reserve for deposit_or_mint)
        let lr_collector_final = coin::balance<ORECoin>(cdpContract::get_lr_collector());
        assert!(lr_collector_final == lr_collector_before_mint, 4);
        
        // Print balances for debugging
        // std::debug::print(&b"Initial borrow fee:");
        // std::debug::print(&expected_fee);
        // std::debug::print(&b"Additional mint fee:");
        // std::debug::print(&additional_fee);
        // std::debug::print(&b"Liquidation reserve:");
        // std::debug::print(&liquidation_reserve);
        // std::debug::print(&b"Final FEE_COLLECTOR balance:");
        // std::debug::print(&fee_collector_final);
        // std::debug::print(&b"Final LR_COLLECTOR balance:");
        // std::debug::print(&lr_collector_final);
        
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

    #[test]
    fun test_set_price() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        let admin = get_admin_account();
        
        // Initialize contract (sets default price of 10 USD)
        cdpContract::initialize(&admin);
        
        // Verify initial price is 10 USD
        let initial_price = cdpContract::get_supra_price();
        let initial_price_u64 = fixed_point32::multiply_u64(10000, initial_price);
        // std::debug::print(&b"Initial price:");
        // std::debug::print(&initial_price_u64);
        assert!(initial_price_u64 == 100000, 0); // Should be 10 USD (scaled)
        
        // Set new price to 15 USD
        cdpContract::set_price(&admin, 15 * 100000000);
        
        // Verify new price
        let new_price = cdpContract::get_supra_price();
        let new_price_u64 = fixed_point32::multiply_u64(10000, new_price);
        // std::debug::print(&b"New price:");
        // std::debug::print(&new_price_u64);
        assert!(new_price_u64 == 150000, 1); // Should be 15 USD (scaled)
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0)] // Using the generic error code we set
    fun test_set_price_unauthorized() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        let admin = get_admin_account();
        let unauthorized = account::create_account_for_test(@0x456);
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Attempt to set price with unauthorized account (should fail)
        cdpContract::set_price(&unauthorized, 15 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_price_affects_collateral_ratio() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        let admin = get_admin_account();
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Set price to 20 USD (double the default)
        cdpContract::set_price(&admin, 20 * 100000000);
        
        // This should pass because price is 20 USD (double collateral value)
        // 500 SUPRA * 20 USD = 10000 USD collateral value
        // 8000 ORE debt requires 10000 USD collateral at 125% MCR
        cdpContract::verify_collateral_ratio(500 * 100000000, 8000 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    // Separate test for the failing case
    #[test]
    #[expected_failure(abort_code = 3)] // ERR_INSUFFICIENT_COLLATERAL = 3
    fun test_price_affects_collateral_ratio_fails() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        let admin = get_admin_account();
        
        // Initialize contract
        cdpContract::initialize(&admin);
        
        // Set price to 10 USD
        cdpContract::set_price(&admin, 10 * 100000000);
        
        // This should fail because with price at 10 USD:
        // 500 SUPRA * 10 USD = 5000 USD collateral value
        // 8000 ORE debt requires 10000 USD collateral at 125% MCR
        cdpContract::verify_collateral_ratio(500 * 100000000, 8000 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_operations_after_price_change() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize framework
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        setup_collector_accounts();
        
        // Register user for coins
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Give user initial SUPRA
        let initial_supra = 1000 * 100000000; // 1000 SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Debug: Print initial SUPRA balance
        // std::debug::print(&b"Initial SUPRA balance:");
        // std::debug::print(&coin::balance<SupraCoin>(user_addr));
        
        // Initial price is 10 USD
        // First operation: Open trove with better collateral ratio
        let deposit_amount = 200 * 100000000; // 200 SUPRA
        let borrow_amount = 800 * 100000000; // 800 ORE
        cdpContract::open_trove(&user, deposit_amount, borrow_amount);
        
        // Debug: Print balances after opening trove
        // std::debug::print(&b"SUPRA balance after opening trove:");
        // std::debug::print(&coin::balance<SupraCoin>(user_addr));
        // std::debug::print(&b"ORE balance after opening trove:");
        // std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Change price to 50 USD
        cdpContract::set_price(&admin, 50 * 100000000);
        
        // Additional operations...
        let additional_mint = 2000 * 100000000; // 2000 more ORE
        cdpContract::deposit_or_mint(&user, 0, additional_mint);
        
        // Debug: Print balances after additional mint
        // std::debug::print(&b"ORE balance after additional mint:");
        // std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        // Before closing trove, make sure we have enough ORE to repay
        let (current_debt, _, _) = cdpContract::get_user_position(user_addr);
        // std::debug::print(&b"Current debt before closing:");
        // std::debug::print(&current_debt);
        
        // Mint enough ORE to cover the debt plus some extra for fees
        let required_ore = current_debt + (current_debt / 10); // Add 10% extra for fees
        cdpContract::mint_ore_for_test(user_addr, required_ore);
        
        // Debug: Print final balances before closing
        // std::debug::print(&b"Final ORE balance before closing:");
        // std::debug::print(&coin::balance<ORECoin>(user_addr));
        
        cdpContract::close_trove(&user);
        
        // Verify trove is closed
        let (final_debt, final_collateral, final_active) = cdpContract::get_user_position(user_addr);
        assert!(final_debt == 0, 10);
        assert!(final_collateral == 0, 11);
        assert!(final_active == false, 12);
        
        // Clean up
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_set_decimal_price() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        let admin = get_admin_account();
        
        // Initialize contract (sets default price of 10 USD)
        cdpContract::initialize(&admin);
        
        // Test various decimal prices
        
        // Test 30.5 USD (30.5 * 10^8 = 3050000000)
        cdpContract::set_price(&admin, 3050000000);
        let price = cdpContract::get_supra_price_raw();
        // std::debug::print(&b"Price set to 30.5 USD, raw value:");
        // std::debug::print(&price);
        // Allow for 1 unit of difference due to potential rounding
        assert!(price >= 3050000000 - 1 && price <= 3050000000 + 1, 0);
        
        // Test 12.34 USD (12.34 * 10^8 = 1234000000)
        cdpContract::set_price(&admin, 1234000000);
        price = cdpContract::get_supra_price_raw();
        // std::debug::print(&b"Price set to 12.34 USD, raw value:");
        // std::debug::print(&price);
        // Allow for 1 unit of difference due to potential rounding
        assert!(price >= 1234000000 - 1 && price <= 1234000000 + 1, 1);
        
        // Test very small price: 0.05 USD (0.05 * 10^8 = 5000000)
        cdpContract::set_price(&admin, 5000000);
        price = cdpContract::get_supra_price_raw();
        // std::debug::print(&b"Price set to 0.05 USD, raw value:");
        // std::debug::print(&price);
        // Allow for 1 unit of difference due to potential rounding
        assert!(price >= 5000000 - 1 && price <= 5000000 + 1, 2);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_trove_state_transitions() {
        // Setup
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        // Initialize framework
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        setup_collector_accounts();
        
        // Register user for coins
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        // Give user initial SUPRA
        let initial_supra = 2000 * 100000000; // 2000 SUPRA
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Test 1: Initial state - should be able to open trove
        let deposit_amount = 1000 * 100000000;
        let borrow_amount = 400 * 100000000;
        cdpContract::open_trove(&user, deposit_amount, borrow_amount);
        
        // Verify trove is active
        let (debt, _, is_active) = cdpContract::get_user_position(user_addr);
        assert!(is_active == true, 1);
        
        // Test 2: Should be able to deposit/mint while active
        cdpContract::deposit_or_mint(&user, 100 * 100000000, 50 * 100000000);
        
        // Test 3: Should be able to repay/withdraw while active
        cdpContract::repay_or_withdraw(&user, 50 * 100000000, 25 * 100000000);
        
        // Get current debt and mint enough ORE to cover it plus fees
        let (current_debt, _, _) = cdpContract::get_user_position(user_addr);
        let extra_buffer = current_debt / 10; // Add 10% extra for fees
        cdpContract::mint_ore_for_test(user_addr, current_debt + extra_buffer);
        
        // Test 4: Close trove
        cdpContract::close_trove(&user);
        
        // Verify trove is inactive
        let (_, _, is_active) = cdpContract::get_user_position(user_addr);
        assert!(is_active == false, 2);
        
        // Test 5: Should be able to open trove again
        cdpContract::open_trove(&user, deposit_amount, borrow_amount);
        
        // Verify trove is active again
        let (_, _, is_active) = cdpContract::get_user_position(user_addr);
        assert!(is_active == true, 3);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_TROVE_ALREADY_ACTIVE)]
    fun test_cannot_open_active_trove() {
        // Similar setup as above...
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        setup_collector_accounts();
        
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        let initial_supra = 2000 * 100000000;
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Open trove first time
        cdpContract::open_trove(&user, 1000 * 100000000, 400 * 100000000);
        
        // Try to open again while active (should fail)
        cdpContract::open_trove(&user, 1000 * 100000000, 400 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    #[expected_failure(abort_code = cdpContract::ERR_NO_TROVE_EXISTS)]
    fun test_cannot_operate_inactive_trove() {
        // Similar setup as above...
        let framework = account::create_account_for_test(@0x1);
        let admin = get_admin_account();
        let user = account::create_account_for_test(@0x456);
        let user_addr = signer::address_of(&user);
        
        let (burn_cap, mint_cap) = supra_framework::supra_coin::initialize_for_test(&framework);
        cdpContract::initialize(&admin);
        setup_collector_accounts();
        
        coin::register<SupraCoin>(&user);
        coin::register<ORECoin>(&user);
        
        let initial_supra = 2000 * 100000000;
        let coins = coin::mint(initial_supra, &mint_cap);
        coin::deposit(user_addr, coins);
        
        // Try to deposit without opening trove first (should fail)
        cdpContract::deposit_or_mint(&user, 100 * 100000000, 50 * 100000000);
        
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }
}