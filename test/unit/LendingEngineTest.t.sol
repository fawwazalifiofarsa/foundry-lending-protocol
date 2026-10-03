// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20DecimalsMock} from "test/mocks/ERC20DecimalsMock.sol";
import {LendingEngine} from "src/LendingEngine.sol";
import {RebaseToken} from "src/RebaseToken.sol";
import {Vault} from "src/Vault.sol";

contract LendingEngineTest is Test {
    LendingEngine public lendingEngine;
    ERC20DecimalsMock public weth;
    ERC20DecimalsMock public usdc;
    RebaseToken public rebaseToken;
    Vault public vault;
    MockV3Aggregator public priceFeed;

    address public user = makeAddr("user");
    address public secondUser = makeAddr("secondUser");
    address public lender = makeAddr("lender");

    int256 private constant ETH_USD_PRICE = 2_000e8;
    uint256 private constant INITIAL_WETH_BALANCE = 100 ether;
    uint256 private constant INITIAL_USDC_LIQUIDITY = 100_000e6;
    uint256 private constant COLLATERAL_AMOUNT = 10 ether;
    uint256 private constant BORROW_AMOUNT = 10_000e6;
    uint256 private constant MAX_BORROW_AMOUNT = 14_000e6;
    uint256 private constant ADDITIONAL_AMOUNT = 1_000e6;

    function setUp() public {
        weth = new ERC20DecimalsMock("Wrapped Ether", "WETH", 18);
        usdc = new ERC20DecimalsMock("USD Coin", "USDC", 6);
        rebaseToken = new RebaseToken("Rebase USDC", "rUSDC");
        vault = new Vault(address(usdc), address(rebaseToken));
        priceFeed = new MockV3Aggregator(8, ETH_USD_PRICE);
        lendingEngine = new LendingEngine(
            address(weth),
            address(vault),
            address(priceFeed)
        );

        rebaseToken.transferOwnership(address(vault));
        vault.setLendingEngine(address(lendingEngine));
        weth.mint(user, INITIAL_WETH_BALANCE);
        weth.mint(secondUser, INITIAL_WETH_BALANCE);
        usdc.mint(lender, INITIAL_USDC_LIQUIDITY);

        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lender);
        vault.deposit(INITIAL_USDC_LIQUIDITY);

        _approveTokens(user);
        _approveTokens(secondUser);
    }

    modifier collateralDeposited() {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        _;
    }

    modifier debtBorrowed() {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        _borrow(user, BORROW_AMOUNT);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function testDepositCollateralRevertsWhenAmountIsZero() public {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        lendingEngine.depositCollateral(0);
    }

    function testDepositCollateralTransfersWethToLendingEngine() public {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        assertEq(weth.balanceOf(address(lendingEngine)), COLLATERAL_AMOUNT);
        assertEq(
            weth.balanceOf(user),
            INITIAL_WETH_BALANCE - COLLATERAL_AMOUNT
        );
    }

    function testDepositCollateralUpdatesUserCollateral() public {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        assertEq(lendingEngine.getCollateral(user), COLLATERAL_AMOUNT);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, false, false, true, address(lendingEngine));
        emit LendingEngine.CollateralDeposited(user, COLLATERAL_AMOUNT);
        lendingEngine.depositCollateral(COLLATERAL_AMOUNT);
    }

    function testMultipleDepositsAccumulateCollateral() public {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        _depositCollateral(user, 1 ether);
        assertEq(
            lendingEngine.getCollateral(user),
            COLLATERAL_AMOUNT + 1 ether
        );
    }

    function testMultipleUsersCanDepositCollateral() public {
        _depositCollateral(user, COLLATERAL_AMOUNT);
        _depositCollateral(secondUser, 2 ether);
        assertEq(lendingEngine.getCollateral(user), COLLATERAL_AMOUNT);
        assertEq(lendingEngine.getCollateral(secondUser), 2 ether);
        assertEq(
            weth.balanceOf(address(lendingEngine)),
            COLLATERAL_AMOUNT + 2 ether
        );
    }

    function testDepositCollateralRevertsWithoutApproval() public {
        address unapprovedUser = makeAddr("unapprovedUser");
        weth.mint(unapprovedUser, COLLATERAL_AMOUNT);
        vm.prank(unapprovedUser);
        vm.expectPartialRevert(
            IERC20Errors.ERC20InsufficientAllowance.selector
        );
        lendingEngine.depositCollateral(COLLATERAL_AMOUNT);
    }

    function testDepositCollateralRevertsWithInsufficientBalance() public {
        address userWithoutWeth = makeAddr("userWithoutWeth");
        vm.prank(userWithoutWeth);
        weth.approve(address(lendingEngine), COLLATERAL_AMOUNT);
        vm.prank(userWithoutWeth);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        lendingEngine.depositCollateral(COLLATERAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function testWithdrawCollateralRevertsWhenAmountIsZero()
        public
        collateralDeposited
    {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        lendingEngine.withdrawCollateral(0);
    }

    function testWithdrawCollateralRevertsWhenAmountExceedsBalance()
        public
        collateralDeposited
    {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxWithdrawAmountExceeded.selector
        );
        lendingEngine.withdrawCollateral(COLLATERAL_AMOUNT + 1);
    }

    function testWithdrawCollateralTransfersWethToUser()
        public
        collateralDeposited
    {
        uint256 balanceBefore = weth.balanceOf(user);
        _withdraw(user, 1 ether);
        assertEq(weth.balanceOf(user), balanceBefore + 1 ether);
    }

    function testWithdrawCollateralReducesUserCollateral()
        public
        collateralDeposited
    {
        _withdraw(user, 1 ether);
        assertEq(
            lendingEngine.getCollateral(user),
            COLLATERAL_AMOUNT - 1 ether
        );
    }

    function testWithdrawCollateralEmitsEvent() public collateralDeposited {
        vm.prank(user);
        vm.expectEmit(true, false, false, true, address(lendingEngine));
        emit LendingEngine.CollateralWithdrawn(user, 1 ether);
        lendingEngine.withdrawCollateral(1 ether);
    }

    function testUserWithoutDebtCanWithdrawAllCollateral()
        public
        collateralDeposited
    {
        _withdraw(user, COLLATERAL_AMOUNT);
        assertEq(lendingEngine.getCollateral(user), 0);
        assertEq(weth.balanceOf(user), INITIAL_WETH_BALANCE);
    }

    function testUserWithDebtCanWithdrawIfHealthFactorRemainsHealthy()
        public
        debtBorrowed
    {
        _withdraw(user, 1 ether);
        assertEq(
            lendingEngine.getCollateral(user),
            COLLATERAL_AMOUNT - 1 ether
        );
        assertGt(lendingEngine.getHealthFactor(user), 1e18);
    }

    function testWithdrawCollateralRevertsIfHealthFactorWouldBeBroken()
        public
        collateralDeposited
    {
        _borrow(user, MAX_BORROW_AMOUNT);
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__HealthFactorBroken.selector
        );
        lendingEngine.withdrawCollateral(2 ether);
    }

    function testWithdrawFailureDoesNotChangeCollateralAccounting()
        public
        collateralDeposited
    {
        _borrow(user, MAX_BORROW_AMOUNT);
        uint256 engineBalanceBefore = weth.balanceOf(address(lendingEngine));
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__HealthFactorBroken.selector
        );
        lendingEngine.withdrawCollateral(2 ether);
        assertEq(lendingEngine.getCollateral(user), COLLATERAL_AMOUNT);
        assertEq(weth.balanceOf(address(lendingEngine)), engineBalanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE ORACLE
    //////////////////////////////////////////////////////////////*/

    function testGetEthUsdValueReturnsCorrectValueForOneWeth() public view {
        assertEq(lendingEngine.getEthUsdValue(1 ether), 2_000e18);
    }

    function testGetEthUsdValueReturnsCorrectValueForMultipleWeth()
        public
        view
    {
        assertEq(lendingEngine.getEthUsdValue(5 ether), 10_000e18);
    }

    function testGetEthUsdValueReflectsPriceFeedChange() public {
        priceFeed.updateAnswer(2_500e8);
        assertEq(lendingEngine.getEthUsdValue(1 ether), 2_500e18);
    }

    /*//////////////////////////////////////////////////////////////
                            BORROW
    //////////////////////////////////////////////////////////////*/

    function testBorrowRevertsWhenAmountIsZero() public collateralDeposited {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        lendingEngine.borrow(0);
    }

    function testBorrowRevertsWithoutCollateral() public {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(1e6);
    }

    function testUserCanBorrowBelowMaxLtv() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        assertEq(lendingEngine.getDebt(user), BORROW_AMOUNT);
    }

    function testUserCanBorrowExactlyAtMaxLtv() public collateralDeposited {
        _borrow(user, MAX_BORROW_AMOUNT);
        assertEq(lendingEngine.getDebt(user), MAX_BORROW_AMOUNT);
    }

    function testBorrowAboveMaxLtvReverts() public collateralDeposited {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(MAX_BORROW_AMOUNT + 1);
    }

    function testBorrowTransfersUsdcToBorrower() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        assertEq(usdc.balanceOf(user), BORROW_AMOUNT);
    }

    function testBorrowIncreasesUserScaledDebt() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        assertEq(vault.totalScaledBorrowed(), BORROW_AMOUNT);
    }

    function testBorrowIncreasesUserDebt() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        assertEq(lendingEngine.getDebt(user), BORROW_AMOUNT);
    }

    function testMultipleBorrowsAccumulateDebt() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        _borrow(user, ADDITIONAL_AMOUNT);
        assertEq(
            lendingEngine.getDebt(user),
            BORROW_AMOUNT + ADDITIONAL_AMOUNT
        );
    }

    function testBorrowDoesNotChangeCollateral() public collateralDeposited {
        _borrow(user, BORROW_AMOUNT);
        assertEq(lendingEngine.getCollateral(user), COLLATERAL_AMOUNT);
    }

    function testBorrowRevertsWhenVaultHasInsufficientLiquidity() public {
        _depositCollateral(user, INITIAL_WETH_BALANCE);
        vm.prank(user);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        lendingEngine.borrow(INITIAL_USDC_LIQUIDITY + 1);
    }

    function testBorrowAfterAccruedInterestUsesCurrentDebt()
        public
        collateralDeposited
    {
        _borrow(user, BORROW_AMOUNT);
        vm.warp(block.timestamp + 365 days);
        uint256 debtBefore = lendingEngine.getDebt(user);
        _borrow(user, ADDITIONAL_AMOUNT);
        assertApproxEqAbs(
            lendingEngine.getDebt(user),
            debtBefore + ADDITIONAL_AMOUNT,
            1
        );
    }

    function testBorrowRevertsWhenInterestMakesNewDebtExceedMaxLtv()
        public
        collateralDeposited
    {
        _borrow(user, MAX_BORROW_AMOUNT - 100e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(1e6);
    }

    /*//////////////////////////////////////////////////////////////
                            REPAY
    //////////////////////////////////////////////////////////////*/

    function testRepayRevertsWhenAmountIsZero() public debtBorrowed {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        lendingEngine.repay(0);
    }

    function testRepayRevertsWhenAmountExceedsDebt() public debtBorrowed {
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxRepayAmountExceeded.selector
        );
        lendingEngine.repay(BORROW_AMOUNT + 1);
    }

    function testRepayTransfersUsdcBackToVault() public debtBorrowed {
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBalanceBefore + ADDITIONAL_AMOUNT
        );
    }

    function testRepayReducesUserScaledDebt() public debtBorrowed {
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(
            vault.totalScaledBorrowed(),
            BORROW_AMOUNT - ADDITIONAL_AMOUNT
        );
    }

    function testRepayReducesUserDebt() public debtBorrowed {
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(
            lendingEngine.getDebt(user),
            BORROW_AMOUNT - ADDITIONAL_AMOUNT
        );
    }

    function testPartialRepayLeavesRemainingDebt() public debtBorrowed {
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(lendingEngine.getDebt(user), 9_000e6);
    }

    function testMultipleRepaymentsReduceDebt() public debtBorrowed {
        _repay(user, ADDITIONAL_AMOUNT);
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(lendingEngine.getDebt(user), 8_000e6);
    }

    function testRepayDoesNotChangeCollateral() public debtBorrowed {
        _repay(user, ADDITIONAL_AMOUNT);
        assertEq(lendingEngine.getCollateral(user), COLLATERAL_AMOUNT);
    }

    function testRepayImprovesHealthFactor() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        _repay(user, ADDITIONAL_AMOUNT);
        assertGt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function testRepayRevertsWithoutUsdcApproval() public debtBorrowed {
        vm.prank(user);
        usdc.approve(address(vault), 0);
        vm.prank(user);
        vm.expectPartialRevert(
            IERC20Errors.ERC20InsufficientAllowance.selector
        );
        lendingEngine.repay(ADDITIONAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        DEBT / INTEREST
    //////////////////////////////////////////////////////////////*/

    function testGetDebtReturnsZeroWhenUserHasNoDebt() public view {
        assertEq(lendingEngine.getDebt(user), 0);
    }

    function testGetDebtReturnsBorrowedAmountImmediatelyAfterBorrow()
        public
        collateralDeposited
    {
        _borrow(user, BORROW_AMOUNT);
        assertEq(lendingEngine.getDebt(user), BORROW_AMOUNT);
    }

    function testGetDebtIncreasesAfterTimePasses() public debtBorrowed {
        vm.warp(block.timestamp + 365 days);
        assertGt(lendingEngine.getDebt(user), BORROW_AMOUNT);
    }

    function testGetDebtUsesPreviewBorrowIndex() public debtBorrowed {
        vm.warp(block.timestamp + 180 days);
        uint256 expectedDebt = (vault.totalScaledBorrowed() *
            vault.previewBorrowIndex()) / 1e18;
        assertEq(lendingEngine.getDebt(user), expectedDebt);
    }

    function testDebtCanIncreaseWithoutStateChangingInteraction()
        public
        debtBorrowed
    {
        uint256 storedBorrowIndex = vault.borrowIndex();
        vm.warp(block.timestamp + 30 days);
        assertGt(lendingEngine.getDebt(user), BORROW_AMOUNT);
        assertEq(vault.borrowIndex(), storedBorrowIndex);
    }

    /*//////////////////////////////////////////////////////////////
                        BORROWING POWER
    //////////////////////////////////////////////////////////////*/

    function testMaxBorrowValueUsesCollateralUsdValue() public {
        _depositCollateral(user, 1 ether);
        _borrow(user, 1_400e6);
        assertEq(lendingEngine.getDebt(user), 1_400e6);
    }

    function testMaxBorrowValueUsesSeventyPercentLtv() public {
        _depositCollateral(user, 1 ether);
        _borrow(user, 1_400e6);
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(1);
    }

    function testMaxBorrowValueChangesWhenEthPriceChanges() public {
        _depositCollateral(user, 1 ether);
        priceFeed.updateAnswer(1_000e8);
        _borrow(user, 700e6);
        vm.prank(user);
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(1);
    }

    /*//////////////////////////////////////////////////////////////
                        HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    function testHealthFactorIsMaxWhenUserHasNoDebt()
        public
        collateralDeposited
    {
        assertEq(lendingEngine.getHealthFactor(user), type(uint256).max);
    }

    function testHealthFactorIsAboveMinimumForHealthyPosition()
        public
        debtBorrowed
    {
        assertGt(lendingEngine.getHealthFactor(user), 1e18);
    }

    function testHealthFactorAtLiquidationBoundaryEqualsOne()
        public
        collateralDeposited
    {
        _borrow(user, MAX_BORROW_AMOUNT);
        priceFeed.updateAnswer(1_750e8);
        assertEq(lendingEngine.getHealthFactor(user), 1e18);
    }

    function testHealthFactorBelowOneForUnsafePosition()
        public
        collateralDeposited
    {
        _borrow(user, MAX_BORROW_AMOUNT);
        priceFeed.updateAnswer(1_700e8);
        assertLt(lendingEngine.getHealthFactor(user), 1e18);
    }

    function testHealthFactorDecreasesWhenEthPriceDrops() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        priceFeed.updateAnswer(1_500e8);
        assertLt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function testHealthFactorIncreasesWhenEthPriceRises() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        priceFeed.updateAnswer(2_500e8);
        assertGt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function testHealthFactorDecreasesWhenDebtIncreases() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        _borrow(user, ADDITIONAL_AMOUNT);
        assertLt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function testHealthFactorDecreasesAsInterestAccrues() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        vm.warp(block.timestamp + 365 days);
        assertLt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function testHealthFactorImprovesAfterRepay() public debtBorrowed {
        uint256 healthFactorBefore = lendingEngine.getHealthFactor(user);
        _repay(user, ADDITIONAL_AMOUNT);
        assertGt(lendingEngine.getHealthFactor(user), healthFactorBefore);
    }

    function _approveTokens(address account) internal {
        vm.startPrank(account);
        weth.approve(address(lendingEngine), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _depositCollateral(address account, uint256 amount) internal {
        vm.prank(account);
        lendingEngine.depositCollateral(amount);
    }

    function _withdraw(address account, uint256 amount) internal {
        vm.prank(account);
        lendingEngine.withdrawCollateral(amount);
    }

    function _borrow(address account, uint256 amount) internal {
        vm.prank(account);
        lendingEngine.borrow(amount);
    }

    function _repay(address account, uint256 amount) internal {
        vm.prank(account);
        lendingEngine.repay(amount);
    }
}
