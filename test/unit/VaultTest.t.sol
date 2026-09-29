// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
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

    address lender = makeAddr("lender");

    function setUp() public {
        usdc = new ERC20DecimalsMock("USD Coin", "USDC", 6);
        rebaseToken = new RebaseToken("Rebase USDC", "rUSDC");
        vault = new Vault(address(usdc), address(rebaseToken));

        rebaseToken.transferOwnership(address(vault));

        usdc.mint(lender, INITIAL_AMOUNT);

        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testGetRebaseTokenAddressReturnsCorrectAddress() public view {
        address vaultRebaseToken = vault.getRebaseTokenAddress();
        assertEq(vaultRebaseToken, address(rebaseToken));
    }

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
}
