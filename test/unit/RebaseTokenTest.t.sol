// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20DecimalsMock} from "test/mocks/ERC20DecimalsMock.sol";
import {RebaseToken} from "src/RebaseToken.sol";
import {Vault} from "src/Vault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RebaseTokenTest is Test {
    ERC20DecimalsMock usdc;
    RebaseToken rebaseToken;
    Vault vault;

    address user = makeAddr("user");

    uint256 constant INITIAL_AMOUNT = 10_000e6;
    uint256 constant ADDITIONAL_AMOUNT = 1_000e6;

    function setUp() public {
        usdc = new ERC20DecimalsMock("USD Coin", "USDC", 6);
        rebaseToken = new RebaseToken("Rebase USDC", "rUSDC");
        vault = new Vault(address(usdc), address(rebaseToken));

        rebaseToken.transferOwnership(address(vault));
    }

    function testOwnerCanSetLiquidityIndex() public {
        vm.prank(address(vault));
        rebaseToken.setLiquidityIndex(2e18);
    }

    function testNonOwnerCannotSetLiquidityIndex() public {
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        rebaseToken.setLiquidityIndex(2e18);
    }

    function testOwnerCanMint() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        uint256 userRebaseTokenAmount = rebaseToken.balanceOf(user);
        assertEq(userRebaseTokenAmount, INITIAL_AMOUNT);
    }

    function testNonOwnerCannotMint() public {
        vm.prank(user);
        vm.expectRevert();
        rebaseToken.setLiquidityIndex(2e18);
    }

    function testMintCreatesCorrectScaledBalanceAtInitialIndex() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        uint256 userRebaseTokenAmount = rebaseToken.scaledBalanceOf(user);
        assertEq(userRebaseTokenAmount, INITIAL_AMOUNT);
    }

    function testMintAtHigherLiquidityIndexDoesNotGivePastInterest() public {}

    function testBalanceOfAppliesLiquidityIndex() public {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.setLiquidityIndex(2e18);
        vm.stopPrank();

        uint256 userScaledBalance = rebaseToken.balanceOf(user);
        assertGt(userScaledBalance, INITIAL_AMOUNT);
    }

    function testScaledBalanceOfDoesNotChangeWhenLiquidityIndexChanges()
        public
    {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.setLiquidityIndex(2e18);
        vm.stopPrank();

        uint256 userScaledBalance = rebaseToken.scaledBalanceOf(user);
        assertEq(userScaledBalance, INITIAL_AMOUNT);
    }

    function testTotalSupplyAppliesLiquidityIndex() public {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.setLiquidityIndex(2e18);
        vm.stopPrank();

        uint256 totalSupply = rebaseToken.totalSupply();
        assertGt(totalSupply, INITIAL_AMOUNT);
    }

    function testOwnerCanBurn() public {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.burn(user, INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function testBurnReducesScaledBalance() public {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.burn(user, INITIAL_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = rebaseToken.scaledBalanceOf(user);
        assertEq(userBalance, 0);
    }

    function testBurnReducesRebasedBalance() public {
        vm.startPrank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        rebaseToken.burn(user, INITIAL_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = rebaseToken.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testNonOwnerCannotBurn() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);

        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        rebaseToken.burn(user, INITIAL_AMOUNT);
    }

    function testCannotBurnMoreThanUserBalance() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);
        vm.expectRevert();
        rebaseToken.burn(user, INITIAL_AMOUNT + ADDITIONAL_AMOUNT);
        vm.stopPrank();
    }

    function testTransferReverts() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);

        vm.prank(user);
        vm.expectRevert(RebaseToken.RebaseToken__TransferNotSupported.selector);
        rebaseToken.transfer(address(this), INITIAL_AMOUNT);
    }

    function testTransferFromReverts() public {
        vm.prank(address(vault));
        rebaseToken.mint(user, INITIAL_AMOUNT);

        vm.prank(user);
        rebaseToken.approve(address(this), INITIAL_AMOUNT);

        vm.expectRevert(RebaseToken.RebaseToken__TransferNotSupported.selector);
        rebaseToken.transferFrom(user, address(this), INITIAL_AMOUNT);
    }
}
