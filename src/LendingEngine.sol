// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title LendingEngine
 * @author Fawwaz Alifio Farsa
 * @notice A simple lending engine for managing collateral, borrowing, repayment, and liquidation
 * @dev Uses a conditional liquidation bonus to keep liquidations health-factor improving. A 10% bonus applies above 110% collateralization, while no bonus is applied between 100% and 110%. Positions at or below 100% collateralization may result in bad debt and are not fully handled by the current liquidation mechanism. Future versions may add bad-debt accounting and a progressively adjusted liquidation bonus.
 */
contract LendingEngine {
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable i_weth;
    IVault public immutable i_usdcVault;
    AggregatorV3Interface public immutable i_ethUsdPriceFeed;

    uint256 private constant MAX_LTV = 70e16; // 70%
    uint256 private constant LIQUIDATION_THRESHOLD = 80e16; // 80%
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    uint256 private constant WAD = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant USDC_TO_WAD = 1e12;
    uint256 private constant MIN_BORROW_AMOUNT = 10e6;
    uint256 private constant MIN_REPAY_AMOUNT = 1e6;

    struct UserPosition {
        uint256 collateral;
        uint256 scaledDebt;
    }

    mapping(address user => UserPosition position) private s_positions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralRedeemed(
        address indexed collateralOwner,
        address indexed collateralRecipient,
        uint256 amount
    );
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtCovered,
        uint256 collaterealRedeemed
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error LendingEngine__NeedsMoreThanZero();
    error LendingEngine__NeedsMoreThanMinimumAmount();
    error LendingEngine__MaxWithdrawAmountExceeded();
    error LendingEngine__MaxBorrowAmountExceeded();
    error LendingEngine__MaxRepayAmountExceeded();
    error LendingEngine__InsufficientCollateral();
    error LendingEngine__TransferFailed();
    error LendingEngine__HealthFactorBroken();
    error LendingEngine__HealthFactorOk(uint256 healthFactor);
    error LendingEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures that an amount is greater than zero
     * @param amount The amount to validate
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier moreThanMinimumBorrowAmount(uint256 _amount) {
        if (_amount < MIN_BORROW_AMOUNT) {
            revert LendingEngine__NeedsMoreThanMinimumAmount();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _weth, address _usdcVault, address _priceFeedAddress) {
        i_weth = IERC20(_weth);
        i_usdcVault = IVault(_usdcVault);
        i_ethUsdPriceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits collateral into the caller's lending position
     * @param _amount The amount of collateral to deposit
     */
    function depositCollateral(uint256 _amount) external moreThanZero(_amount) {
        s_positions[msg.sender].collateral += _amount;

        bool success = i_weth.transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert LendingEngine__TransferFailed();
        }

        emit CollateralDeposited(msg.sender, _amount);
    }

    /**
     * @notice Withdraws collateral from the caller's lending position
     * @dev Reverts if the amount exceeds the caller's collateral or leaves the position undercollateralized
     * @param _amount The amount of collateral to withdraw
     */
    function withdrawCollateral(
        uint256 _amount
    ) external moreThanZero(_amount) {
        if (_amount > s_positions[msg.sender].collateral) {
            revert LendingEngine__MaxWithdrawAmountExceeded();
        }

        _redeemCollateral(msg.sender, msg.sender, _amount);

        _revertIfHealthFactorBroken(msg.sender);
    }

    /**
     * @notice Increases the caller's debt by borrowing against their collateral
     * @dev Reverts if the resulting debt exceeds the caller's maximum borrow amount
     * @param _amount The amount to borrow
     */
    function borrow(uint256 _amount) external moreThanZero(_amount) {
        if (_amount < MIN_BORROW_AMOUNT) {
            revert LendingEngine__NeedsMoreThanMinimumAmount();
        }

        uint256 maxBorrowValueUsd = _getMaxBorrowValueUsd(msg.sender);
        uint256 currentDebtValueUsd = _getDebtValueUsd(msg.sender);
        uint256 newDebtValueUsd = currentDebtValueUsd + (_amount * USDC_TO_WAD);

        if (newDebtValueUsd > maxBorrowValueUsd) {
            revert LendingEngine__MaxBorrowAmountExceeded();
        }

        uint256 scaledAmount = i_usdcVault.borrow(msg.sender, _amount);

        s_positions[msg.sender].scaledDebt += scaledAmount;
    }

    /**
     * @notice Repays a portion of the caller's outstanding debt
     * @param _amount The amount of debt to repay
     */
    function repay(uint256 _amount) external moreThanZero(_amount) {
        uint256 userDebt = getDebt(msg.sender);

        if (_amount > userDebt) {
            revert LendingEngine__MaxRepayAmountExceeded();
        }

        if (_amount < MIN_REPAY_AMOUNT && _amount != userDebt) {
            revert LendingEngine__NeedsMoreThanMinimumAmount();
        }

        _repay(msg.sender, msg.sender, _amount);
    }

    /**
     * @notice Returns the collateral balance of a user
     * @param user The address whose collateral balance is queried
     * @return The user's collateral balance
     */
    function getCollateral(address user) external view returns (uint256) {
        return s_positions[user].collateral;
    }

    /**
     * @notice Liquidates part of an unhealthy borrower's debt in exchange for collateral plus a liquidation bonus
     * @dev The target user's health factor must be below the minimum health factor before liquidation.
     * The liquidation must improve the user's health factor, although it is not required to restore it above the minimum threshold.
     * This allows partial liquidations while preventing liquidations that would further worsen an already unhealthy position.
     * @param _user The address of the borrower being liquidated
     * @param _debtToCover The amount of the borrower's USDC debt to repay
     */
    function liquidate(
        address _user,
        uint256 _debtToCover
    ) external moreThanZero(_debtToCover) {
        uint256 startingUserHealthFactor = getHealthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert LendingEngine__HealthFactorOk(startingUserHealthFactor);
        }

        uint256 liquidationBonus = _getLiquidationBonus(_user);

        _repay(_user, msg.sender, _debtToCover);

        uint256 debtValueUsd = _debtToCover * USDC_TO_WAD;
        uint256 tokenAmountFromDebtCovered = getEthAmountFromUsd(debtValueUsd);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            liquidationBonus) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(_user, msg.sender, totalCollateralToRedeem);

        uint256 endingUserHealthFactor = getHealthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert LendingEngine__HealthFactorNotImproved();
        }

        emit Liquidated(
            _user,
            msg.sender,
            _debtToCover,
            totalCollateralToRedeem
        );
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the outstanding debt of a user
     * @param _user The address whose debt is queried
     * @return The user's outstanding debt
     */
    function getDebt(address _user) public view returns (uint256) {
        return
            Math.mulDiv(
                s_positions[_user].scaledDebt,
                i_usdcVault.previewBorrowIndex(),
                WAD,
                Math.Rounding.Ceil
            );
    }

    /**
     * @notice Returns the USD value of a given amount of ETH
     * @param _amount The amount of ETH
     * @return The USD value
     */
    function getEthUsdValue(uint256 _amount) public view returns (uint256) {
        uint256 price = _getEthPrice();

        return (price * _amount) / WAD;
    }

    /**
     * @notice Returns the health factor of a user
     * @param _user The address of the user
     * @return The health factor
     */
    function getHealthFactor(address _user) public view returns (uint256) {
        uint256 collateralValueUsd = getEthUsdValue(
            s_positions[_user].collateral
        );

        uint256 debtValueUsd = getDebt(_user) * USDC_TO_WAD;

        return _calculateHealthFactor(collateralValueUsd, debtValueUsd);
    }

    /**
     * @notice Converts a USD-denominated WAD amount into its equivalent ETH amount
     * @param _usdAmountWad The USD amount expressed with 18 decimals
     * @return The equivalent ETH amount expressed with 18 decimals
     */
    function getEthAmountFromUsd(
        uint256 _usdAmountWad
    ) public view returns (uint256) {
        uint256 price = _getEthPrice();

        return (_usdAmountWad * WAD) / price;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the health factor for a user based on their collateral and debt
     * @param _collateralValueUsd The USD value of the user's collateral
     * @param _debtValueUsd The USD value of the user's debt
     * @return The calculated health factor
     */
    function _calculateHealthFactor(
        uint256 _collateralValueUsd,
        uint256 _debtValueUsd
    ) internal pure returns (uint256) {
        if (_debtValueUsd == 0) {
            return type(uint256).max;
        }

        uint256 adjustedCollateral = (_collateralValueUsd *
            LIQUIDATION_THRESHOLD) / WAD;

        return (adjustedCollateral * WAD) / _debtValueUsd;
    }

    /**
     * @notice Returns the USD value of a user's outstanding debt
     * @param _user The address of the user
     * @return The USD value of the user's debt
     */
    function _getDebtValueUsd(address _user) internal view returns (uint256) {
        return getDebt(_user) * USDC_TO_WAD;
    }

    /**
     * @notice Returns the maximum USD value that a user can borrow based on their collateral
     * @param _user The address of the user
     * @return The maximum borrowable USD value
     */
    function _getMaxBorrowValueUsd(
        address _user
    ) internal view returns (uint256) {
        uint256 collateralValueUsd = getEthUsdValue(
            s_positions[_user].collateral
        );

        return (collateralValueUsd * MAX_LTV) / WAD;
    }

    /**
     * @notice Reverts if the user's health factor is below the minimum threshold
     * @param _user The address of the user
     */
    function _revertIfHealthFactorBroken(address _user) internal view {
        uint256 healthFactor = getHealthFactor(_user);

        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert LendingEngine__HealthFactorBroken();
        }
    }

    /**
     * @notice Returns the latest ETH/USD price normalized to WAD precision
     * @return The ETH/USD price expressed with 18 decimals
     */
    function _getEthPrice() internal view returns (uint256) {
        (, int256 priceInt, , , ) = i_ethUsdPriceFeed
            .staleCheckLatestRoundData();
        uint256 price = uint256(priceInt);

        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Returns a user's collateral value relative to their outstanding debt
     * @dev Returns the maximum uint256 value when the user has no debt
     * @param _user The address of the user whose collateralization ratio is queried
     * @return The collateralization ratio expressed in WAD precision
     */
    function _getCollateralizationRatio(
        address _user
    ) internal view returns (uint256) {
        uint256 debtValueUsd = _getDebtValueUsd(_user);

        if (debtValueUsd == 0) {
            return type(uint256).max;
        }

        uint256 collateralValueUsd = getEthUsdValue(
            s_positions[_user].collateral
        );

        return Math.mulDiv(collateralValueUsd, WAD, debtValueUsd);
    }

    /**
     * @notice Returns the liquidation bonus applicable to a user's position
     * @dev Applies the configured bonus only when collateralization exceeds the debt value plus the bonus percentage
     * @param _user The address of the user whose liquidation bonus is queried
     * @return The liquidation bonus expressed in LIQUIDATION_PRECISION units
     */
    function _getLiquidationBonus(
        address _user
    ) internal view returns (uint256) {
        uint256 collateralizationRatio = _getCollateralizationRatio(_user);

        uint256 minimumCollateralizationForBonus = WAD +
            Math.mulDiv(LIQUIDATION_BONUS, WAD, LIQUIDATION_PRECISION);

        if (collateralizationRatio > minimumCollateralizationForBonus) {
            return LIQUIDATION_BONUS;
        }

        return 0;
    }

    /**
     * @notice Redeems collateral from one user's position and transfers it to a recipient
     * @dev Reverts if the requested amount exceeds the collateral owner's balance or the transfer fails
     * @param _collateralOwner The user whose collateral balance is reduced
     * @param _collateralRecipient The address receiving the collateral
     * @param _amount The amount of collateral to redeem
     */
    function _redeemCollateral(
        address _collateralOwner,
        address _collateralRecipient,
        uint256 _amount
    ) private {
        if (_amount > s_positions[_collateralOwner].collateral) {
            revert LendingEngine__InsufficientCollateral();
        }

        s_positions[_collateralOwner].collateral -= _amount;

        bool success = i_weth.transfer(_collateralRecipient, _amount);
        if (!success) {
            revert LendingEngine__TransferFailed();
        }

        emit CollateralRedeemed(
            _collateralOwner,
            _collateralRecipient,
            _amount
        );
    }

    /**
     * @notice Repays debt for a borrower using funds supplied by a payer
     * @dev Reverts if the repayment amount exceeds the borrower's current debt
     * @param _debtOwner The borrower whose debt is reduced
     * @param _debtPayer The address supplying the repayment funds
     * @param _amount The amount of USDC debt to repay
     */
    function _repay(
        address _debtOwner,
        address _debtPayer,
        uint256 _amount
    ) private {
        uint256 userDebt = getDebt(_debtOwner);

        if (_amount > userDebt) {
            revert LendingEngine__MaxRepayAmountExceeded();
        }

        uint256 scaledAmount = i_usdcVault.repay(_debtPayer, _amount);

        s_positions[_debtOwner].scaledDebt -= scaledAmount;
    }
}
