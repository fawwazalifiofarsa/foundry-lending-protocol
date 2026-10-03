// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20DecimalsMock} from "test/mocks/ERC20DecimalsMock.sol";
import {RebaseToken} from "src/RebaseToken.sol";
import {Vault} from "src/Vault.sol";

contract VaultTest is Test {
    ERC20DecimalsMock usdc;
    RebaseToken rebaseToken;
    Vault vault;

    uint256 private constant BASE_RATE = 2e16; // 2%
    uint256 private constant RATE_SLOPE = 10e16; // 10%
    uint256 private constant RESERVE_FACTOR = 10e16; // 10%

    uint256 constant INITIAL_AMOUNT = 10_000e6;
    uint256 constant DEPOSIT_AMOUNT = 8_000e6;
    uint256 constant ADDITIONAL_AMOUNT = 1_000e6;
    uint256 constant BORROW_AMOUNT = 2_000e6;
    uint256 constant WAD = 1e18;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address lendingEngine = makeAddr("lendingEngine");

    function setUp() public {
        usdc = new ERC20DecimalsMock("USD Coin", "USDC", 6);
        rebaseToken = new RebaseToken("Rebase USDC", "rUSDC");
        vault = new Vault(address(usdc), address(rebaseToken));

        rebaseToken.transferOwnership(address(vault));

        usdc.mint(lender, INITIAL_AMOUNT);

        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function testGetRebaseTokenAddressReturnsCorrectAddress() public view {
        address vaultRebaseToken = vault.getRebaseTokenAddress();
        assertEq(vaultRebaseToken, address(rebaseToken));
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function testDepositRevertsWhenAmountIsZero() public {
        vm.prank(lender);
        vm.expectRevert(Vault.Vault__NeedsMoreThanZero.selector);
        vault.deposit(0);
    }

    modifier depositToVault() {
        vm.prank(lender);
        vault.deposit(DEPOSIT_AMOUNT);
        _;
    }

    function testDepositIncreasesAvailableLiquidity() public depositToVault {
        uint256 vaultAvailableLiquidity = vault.getAvailableLiquidity();
        assertEq(vaultAvailableLiquidity, DEPOSIT_AMOUNT);
    }

    function testDepositMintsRebaseTokenToLender() public depositToVault {
        uint256 lenderRebaseToken = rebaseToken.scaledBalanceOf(lender);
        assertEq(lenderRebaseToken, DEPOSIT_AMOUNT);
    }

    function testDepositEmitsDepositEvent() public {
        vm.prank(lender);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.Deposit(lender, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
    }

    function testDepositDoesNotIncreaseTotalBorrowed() public depositToVault {
        uint256 vaultTotalBorrowed = vault.getTotalBorrowed();
        assertEq(vaultTotalBorrowed, 0);
    }

    function testDepositKeepsUtilizationAtZeroWithoutBorrowing()
        public
        depositToVault
    {
        uint256 utilization = vault.getUtilization();
        assertEq(utilization, 0);
    }

    function testDepositKeepsSupplyRateAtZeroWithoutBorrowing()
        public
        depositToVault
    {
        uint256 supplyRate = vault.currentSupplyRate();
        assertEq(supplyRate, 0);
    }

    function testDepositKeepsBorrowRateAtBaseRateWithoutBorrowing()
        public
        depositToVault
    {
        uint256 borrowRate = vault.currentBorrowRate();
        assertEq(borrowRate, BASE_RATE);
    }

    function testDepositRevertsWhenUserHasInsufficientUnderlyingBalance()
        public
    {
        address newLender = makeAddr("newLender");

        vm.prank(newLender);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT);
    }

    function testMultipleDepositsIncreaseVaultLiquidity()
        public
        depositToVault
    {
        vm.prank(lender);
        vault.deposit(ADDITIONAL_AMOUNT);

        uint256 vaultAvailableLiquidity = vault.getAvailableLiquidity();
        assertEq(vaultAvailableLiquidity, DEPOSIT_AMOUNT + ADDITIONAL_AMOUNT);
    }

    function testMultipleLendersCanDeposit() public depositToVault {
        address newLender = makeAddr("newLender");

        usdc.mint(newLender, INITIAL_AMOUNT);

        vm.startPrank(newLender);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 vaultAvailableLiquidity = vault.getAvailableLiquidity();
        assertEq(vaultAvailableLiquidity, DEPOSIT_AMOUNT * 2);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testWithdrawRevertsWhenAmountIsZero() public depositToVault {
        vm.prank(lender);
        vm.expectRevert(Vault.Vault__NeedsMoreThanZero.selector);
        vault.withdraw(0);
    }

    modifier withdrawFromVault(uint256 amount) {
        vm.prank(lender);
        vault.withdraw(amount);
        _;
    }

    function testWithdrawBurnsLenderRebaseTokens()
        public
        depositToVault
        withdrawFromVault(DEPOSIT_AMOUNT)
    {
        uint256 lenderRebaseTokenAmount = rebaseToken.balanceOf(lender);
        assertEq(lenderRebaseTokenAmount, 0);
    }

    function testWithdrawTransfersUnderlyingBackToLender()
        public
        depositToVault
        withdrawFromVault(DEPOSIT_AMOUNT)
    {
        uint256 lenderBalance = usdc.balanceOf(lender);
        assertEq(lenderBalance, INITIAL_AMOUNT);
    }

    function testWithdrawDecreasesAvailableLiquidity()
        public
        depositToVault
        withdrawFromVault(DEPOSIT_AMOUNT)
    {
        uint256 vaultAvailableLiquidity = vault.getAvailableLiquidity();
        assertEq(vaultAvailableLiquidity, 0);
    }

    function testWithdrawEmitsWithdrawEvent() public depositToVault {
        vm.prank(lender);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Vault.Withdraw(lender, DEPOSIT_AMOUNT);
        vault.withdraw(DEPOSIT_AMOUNT);
    }

    function testPartialWithdrawLeavesRemainingRebaseBalance()
        public
        depositToVault
        withdrawFromVault(ADDITIONAL_AMOUNT)
    {
        uint256 lenderBalance = rebaseToken.balanceOf(lender);
        assertEq(lenderBalance, DEPOSIT_AMOUNT - ADDITIONAL_AMOUNT);

        uint256 lenderScaledBalance = rebaseToken.scaledBalanceOf(lender);
        assertEq(lenderScaledBalance, DEPOSIT_AMOUNT - ADDITIONAL_AMOUNT);
    }

    function testFullWithdrawRemovesEntireRebaseBalance()
        public
        depositToVault
        withdrawFromVault(DEPOSIT_AMOUNT)
    {
        uint256 lenderBalance = rebaseToken.balanceOf(lender);
        assertEq(lenderBalance, 0);

        uint256 lenderScaledBalance = rebaseToken.scaledBalanceOf(lender);
        assertEq(lenderScaledBalance, 0);
    }

    function testWithdrawMoreThanLenderClaimReverts() public depositToVault {
        vm.prank(lender);
        vm.expectRevert();
        vault.withdraw(DEPOSIT_AMOUNT + ADDITIONAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCOUNTING WITHOUT BORROWING
    //////////////////////////////////////////////////////////////*/

    function testDepositThenWithdrawKeepsUtilizationAtZero()
        public
        depositToVault
        withdrawFromVault(ADDITIONAL_AMOUNT)
    {
        uint256 utilization = vault.getUtilization();
        assertEq(utilization, 0);
    }

    function testGetTotalBorrowedReturnsZeroWithoutBorrowing()
        public
        depositToVault
    {
        uint256 totalBorrowed = vault.getTotalBorrowed();
        assertEq(totalBorrowed, 0);
    }

    function testInterestAccrualUpdatesLastUpdateTimestampOnInteraction()
        public
    {
        uint256 initialTimestamp = vault.lastUpdateTimestamp();

        vm.warp(initialTimestamp + 1 days);

        vm.prank(lender);
        vault.deposit(DEPOSIT_AMOUNT);

        assertEq(vault.lastUpdateTimestamp(), block.timestamp);
        assertGt(vault.lastUpdateTimestamp(), initialTimestamp);
    }

    function testLiquidityIndexDoesNotIncreaseWithoutBorrowers()
        public
        depositToVault
    {
        uint256 liquidityIndex = vault.liquidityIndex();
        assertEq(liquidityIndex, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        LENDING ENGINE SETUP
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanSetLendingEngine() public {
        vault.setLendingEngine(lendingEngine);

        assertEq(vault.lendingEngine(), lendingEngine);
    }

    function testNonOwnerCannotSetLendingEngine() public {
        vm.prank(lender);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        vault.setLendingEngine(lendingEngine);
    }

    function testCannotSetLendingEngineToZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidAddress.selector);
        vault.setLendingEngine(address(0));
    }

    function testCannotSetLendingEngineMoreThanOnce() public {
        vault.setLendingEngine(lendingEngine);

        vm.expectRevert(Vault.Vault__LendingEngineAlreadySet.selector);
        vault.setLendingEngine(makeAddr("newLendingEngine"));
    }

    /*//////////////////////////////////////////////////////////////
                                BORROW
    //////////////////////////////////////////////////////////////*/

    function testBorrowRevertsWhenCallerIsNotLendingEngine()
        public
        depositToVault
    {
        vault.setLendingEngine(lendingEngine);

        vm.prank(borrower);
        vm.expectRevert(Vault.Vault__OnlyLendingEngine.selector);
        vault.borrow(borrower, BORROW_AMOUNT);
    }

    function testBorrowRevertsWhenAmountIsZero() public depositToVault {
        vault.setLendingEngine(lendingEngine);

        vm.prank(lendingEngine);
        vm.expectRevert(Vault.Vault__NeedsMoreThanZero.selector);
        vault.borrow(borrower, 0);
    }

    function testBorrowTransfersUsdcToBorrower() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
    }

    function testBorrowReducesAvailableLiquidity() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(vault.getAvailableLiquidity(), DEPOSIT_AMOUNT - BORROW_AMOUNT);
    }

    function testBorrowIncreasesTotalScaledBorrowed() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(vault.totalScaledBorrowed(), BORROW_AMOUNT);
    }

    function testBorrowIncreasesTotalBorrowed() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(vault.getTotalBorrowed(), BORROW_AMOUNT);
    }

    function testBorrowReturnsCorrectScaledAmount() public depositToVault {
        vault.setLendingEngine(lendingEngine);

        vm.prank(lendingEngine);
        uint256 scaledAmount = vault.borrow(borrower, BORROW_AMOUNT);

        assertEq(scaledAmount, BORROW_AMOUNT);
    }

    function testBorrowUpdatesUtilization() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(
            vault.getUtilization(),
            (BORROW_AMOUNT * WAD) / DEPOSIT_AMOUNT
        );
    }

    function testBorrowUpdatesBorrowRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 utilization = vault.getUtilization();

        assertEq(
            vault.currentBorrowRate(),
            BASE_RATE + ((utilization * RATE_SLOPE) / WAD)
        );
    }

    function testBorrowUpdatesSupplyRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 utilization = vault.getUtilization();
        uint256 borrowRate = vault.currentBorrowRate();
        uint256 expectedSupplyRate = (((borrowRate * utilization) / WAD) *
            (WAD - RESERVE_FACTOR)) / WAD;

        assertEq(vault.currentSupplyRate(), expectedSupplyRate);
    }

    function testMultipleBorrowsIncreaseTotalScaledBorrowed()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        vm.prank(lendingEngine);
        vault.borrow(borrower, ADDITIONAL_AMOUNT);

        assertEq(
            vault.totalScaledBorrowed(),
            BORROW_AMOUNT + ADDITIONAL_AMOUNT
        );
    }

    function testBorrowRevertsWhenVaultHasInsufficientLiquidity()
        public
        depositToVault
    {
        vault.setLendingEngine(lendingEngine);

        vm.prank(lendingEngine);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.borrow(borrower, DEPOSIT_AMOUNT + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                REPAY
    //////////////////////////////////////////////////////////////*/

    function testRepayRevertsWhenCallerIsNotLendingEngine()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        vm.prank(borrower);
        vm.expectRevert(Vault.Vault__OnlyLendingEngine.selector);
        vault.repay(borrower, ADDITIONAL_AMOUNT);
    }

    function testRepayRevertsWhenAmountIsZero() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        vm.prank(lendingEngine);
        vm.expectRevert(Vault.Vault__NeedsMoreThanZero.selector);
        vault.repay(borrower, 0);
    }

    function testRepayTransfersUsdcFromPayerToVault() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        _repay(ADDITIONAL_AMOUNT);

        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBalanceBefore + ADDITIONAL_AMOUNT
        );
    }

    function testRepayIncreasesAvailableLiquidity() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        _repay(ADDITIONAL_AMOUNT);

        assertEq(
            vault.getAvailableLiquidity(),
            DEPOSIT_AMOUNT - BORROW_AMOUNT + ADDITIONAL_AMOUNT
        );
    }

    function testRepayReducesTotalScaledBorrowed() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        _repay(ADDITIONAL_AMOUNT);

        assertEq(
            vault.totalScaledBorrowed(),
            BORROW_AMOUNT - ADDITIONAL_AMOUNT
        );
    }

    function testRepayReducesTotalBorrowed() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        _repay(ADDITIONAL_AMOUNT);

        assertEq(vault.getTotalBorrowed(), BORROW_AMOUNT - ADDITIONAL_AMOUNT);
    }

    function testRepayReturnsCorrectScaledAmount() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        vm.prank(lendingEngine);
        uint256 scaledAmount = vault.repay(borrower, ADDITIONAL_AMOUNT);

        assertEq(scaledAmount, ADDITIONAL_AMOUNT);
    }

    function testRepayReducesUtilization() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();
        uint256 utilizationBefore = vault.getUtilization();

        _repay(ADDITIONAL_AMOUNT);

        assertLt(vault.getUtilization(), utilizationBefore);
    }

    function testRepayUpdatesBorrowRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        _repay(ADDITIONAL_AMOUNT);
        uint256 utilization = vault.getUtilization();

        assertEq(
            vault.currentBorrowRate(),
            BASE_RATE + ((utilization * RATE_SLOPE) / WAD)
        );
    }

    function testRepayUpdatesSupplyRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();

        _repay(ADDITIONAL_AMOUNT);
        uint256 utilization = vault.getUtilization();
        uint256 borrowRate = vault.currentBorrowRate();
        uint256 expectedSupplyRate = (((borrowRate * utilization) / WAD) *
            (WAD - RESERVE_FACTOR)) / WAD;

        assertEq(vault.currentSupplyRate(), expectedSupplyRate);
    }

    function testRepayRevertsWithoutUsdcApproval() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        vm.prank(lendingEngine);
        vm.expectPartialRevert(
            IERC20Errors.ERC20InsufficientAllowance.selector
        );
        vault.repay(borrower, ADDITIONAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        PREVIEW BORROW INDEX
    //////////////////////////////////////////////////////////////*/

    function testPreviewBorrowIndexEqualsStoredBorrowIndexWhenNoTimePassed()
        public
        view
    {
        assertEq(vault.previewBorrowIndex(), vault.borrowIndex());
    }

    function testPreviewBorrowIndexIncreasesAfterTimePasses() public {
        uint256 storedBorrowIndex = vault.borrowIndex();
        vm.warp(block.timestamp + 365 days);

        assertGt(vault.previewBorrowIndex(), storedBorrowIndex);
    }

    function testPreviewBorrowIndexDoesNotModifyStoredBorrowIndex() public {
        uint256 storedBorrowIndex = vault.borrowIndex();
        vm.warp(block.timestamp + 365 days);

        vault.previewBorrowIndex();

        assertEq(vault.borrowIndex(), storedBorrowIndex);
    }

    function testPreviewBorrowIndexMatchesStoredIndexAfterAccrual()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        vm.warp(block.timestamp + 365 days);
        uint256 previewedIndex = vault.previewBorrowIndex();

        _accrueInterest();

        assertEq(vault.borrowIndex(), previewedIndex);
        assertEq(vault.previewBorrowIndex(), vault.borrowIndex());
    }

    /*//////////////////////////////////////////////////////////////
                            BORROW INTEREST
    //////////////////////////////////////////////////////////////*/

    function testBorrowIndexIncreasesAfterTimePassesWithDebt()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 borrowIndexBefore = vault.borrowIndex();
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertGt(vault.borrowIndex(), borrowIndexBefore);
    }

    function testTotalBorrowedIncreasesAfterInterestAccrues()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 totalBorrowedBefore = vault.getTotalBorrowed();
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertGt(vault.getTotalBorrowed(), totalBorrowedBefore);
    }

    function testBorrowInterestUsesCurrentBorrowRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 borrowIndexBefore = vault.borrowIndex();
        uint256 expectedBorrowIndex = (borrowIndexBefore *
            (WAD + vault.currentBorrowRate())) / WAD;
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertEq(vault.borrowIndex(), expectedBorrowIndex);
    }

    function testBorrowAccrualUpdatesLastUpdateTimestamp()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        vm.warp(block.timestamp + 30 days);

        _accrueInterest();

        assertEq(vault.lastUpdateTimestamp(), block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            SUPPLY INTEREST
    //////////////////////////////////////////////////////////////*/

    function testLiquidityIndexIncreasesWhenThereIsBorrowing()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 liquidityIndexBefore = vault.liquidityIndex();
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertGt(vault.liquidityIndex(), liquidityIndexBefore);
    }

    function testLenderRebaseBalanceIncreasesAfterInterestAccrues()
        public
        depositToVault
    {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 lenderBalanceBefore = rebaseToken.balanceOf(lender);
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertGt(rebaseToken.balanceOf(lender), lenderBalanceBefore);
    }

    function testSupplyInterestUsesCurrentSupplyRate() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        uint256 liquidityIndexBefore = vault.liquidityIndex();
        uint256 expectedLiquidityIndex = (liquidityIndexBefore *
            (WAD + vault.currentSupplyRate())) / WAD;
        vm.warp(block.timestamp + 365 days);

        _accrueInterest();

        assertEq(vault.liquidityIndex(), expectedLiquidityIndex);
    }

    /*//////////////////////////////////////////////////////////////
                        UTILIZATION AND RATES
    //////////////////////////////////////////////////////////////*/

    function testUtilizationIsCorrectAfterBorrow() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertEq(vault.getUtilization(), 25e16);
    }

    function testUtilizationDecreasesAfterRepay() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();
        uint256 utilizationBefore = vault.getUtilization();

        _repay(ADDITIONAL_AMOUNT);

        assertLt(vault.getUtilization(), utilizationBefore);
    }

    function testBorrowRateIncreasesWithUtilization() public depositToVault {
        uint256 borrowRateBefore = vault.currentBorrowRate();
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertGt(vault.currentBorrowRate(), borrowRateBefore);
    }

    function testBorrowRateDecreasesAfterRepay() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();
        uint256 borrowRateBefore = vault.currentBorrowRate();

        _repay(ADDITIONAL_AMOUNT);

        assertLt(vault.currentBorrowRate(), borrowRateBefore);
    }

    function testSupplyRateIncreasesWhenLiquidityIsBorrowed()
        public
        depositToVault
    {
        uint256 supplyRateBefore = vault.currentSupplyRate();
        _setLendingEngineAndBorrow(BORROW_AMOUNT);

        assertGt(vault.currentSupplyRate(), supplyRateBefore);
    }

    function testSupplyRateDecreasesAfterRepay() public depositToVault {
        _setLendingEngineAndBorrow(BORROW_AMOUNT);
        _approveVaultFromBorrower();
        uint256 supplyRateBefore = vault.currentSupplyRate();

        _repay(ADDITIONAL_AMOUNT);

        assertLt(vault.currentSupplyRate(), supplyRateBefore);
    }

    function testRatesAreCorrectAtTwentyPercentUtilization()
        public
        depositToVault
    {
        uint256 twentyPercentBorrow = (DEPOSIT_AMOUNT * 20) / 100;
        _setLendingEngineAndBorrow(twentyPercentBorrow);
        uint256 expectedBorrowRate = BASE_RATE + 2e16;
        uint256 expectedSupplyRate = (((expectedBorrowRate * 20e16) / WAD) *
            (WAD - RESERVE_FACTOR)) / WAD;

        assertEq(vault.getUtilization(), 20e16);
        assertEq(vault.currentBorrowRate(), expectedBorrowRate);
        assertEq(vault.currentSupplyRate(), expectedSupplyRate);
    }

    function _setLendingEngineAndBorrow(uint256 amount) internal {
        vault.setLendingEngine(lendingEngine);
        vm.prank(lendingEngine);
        vault.borrow(borrower, amount);
    }

    function _approveVaultFromBorrower() internal {
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _repay(uint256 amount) internal {
        vm.prank(lendingEngine);
        vault.repay(borrower, amount);
    }

    function _accrueInterest() internal {
        vm.prank(lendingEngine);
        vault.accrueInterest();
    }
}
