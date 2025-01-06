// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author ArefXV
 *
 * The system is designed as minimal as possible , and have the tokens maintain 1 token == $1 peg.
 * This stable coin has the properties :
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governanace, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the valueof all collateral <= the $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /*/////////////////////////////////////////////////////
    //////////               ERRORS              //////////
    /////////////////////////////////////////////////////*/
    error DSCEngine__TokenAddressesLengthMustMatchWithPriceFeeds();
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroke(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*/////////////////////////////////////////////////////
    //////////           STATE VARIABLES         //////////
    /////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION  = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    address[] private s_collateralTokens;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => uint256 amountDsc) private s_DSCMinted;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    /*/////////////////////////////////////////////////////
    //////////               EVENTS              //////////
    /////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /*/////////////////////////////////////////////////////
    //////////               MODIFIERS           //////////
    /////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*/////////////////////////////////////////////////////
    //////////          SPECIAL FUNCTIONS        //////////
    /////////////////////////////////////////////////////*/
    constructor(address[] memory tokenCollateralAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenCollateralAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesLengthMustMatchWithPriceFeeds();
        }

        for (uint256 i = 0; i < tokenCollateralAddresses.length; i++) {
            s_priceFeeds[tokenCollateralAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenCollateralAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*/////////////////////////////////////////////////////
    //////////         EXTERNAL FUNCTIONS        //////////
    /////////////////////////////////////////////////////*/

    /*
    * @param tokenCollateral: The address of the token to deposit as collateral.
    * @param amountCollateral: The amount of collDateral to deposit.
    * @param amountDsc: The amount of DSC to mint.
    * @notice This function allows users to deposit collateral and mint DSC.
    */
    function depositCollateralAndMintDsc(address tokenCollateral, uint256 amountCollateral, uint256 amountDsc)
        external
    {
        depositCollateral(tokenCollateral, amountCollateral);
        mintDsc(amountDsc);
    }

     /*
    * @param tokenCollateral: the collateral address to redeem
    * @param amountCollateral: the amount of collateral to redeem
    * @param amountDscToBurn: the amount of DSC to burn
    * This function burns DSC and redeems collateral
    */
    function redeemCollateralForDsc(address tokenCollateral, uint256 amountCollateral,  uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateral, amountCollateral);
    }

    //IMPORTANT FUNCTION
    //The reason that we are always going to have more collateral, if the value of their collateral drops too much
    //Example:
    //If I put in $100 worth of ETH and minted $50 DSC, I have more collateral than DSC. What if the ETH price drops to $40? now we are under collaterize, we have less ETH than we have DSC, and I shoud get what's called liquidated. I shouldn't be allowed to hold a position in the system anymore
    //This function is going to be the function that other users can call to remove people's position to save the protocol
    //If we do start nearing undercollateralization, we need someone to liquidate positions
    //If someone is almost undercollateralized, we will pay you to liquidate them!
    /**
     * @param collateral the erc20 collateral address to liquidate from the user
     * @param user the user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover the amount of DSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For Example, if the price of collateral plummeted before anyone could be liquidated.
     *
     * Follows CEI
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*/////////////////////////////////////////////////////
    //////////          PUBLIC FUNCTIONS         //////////
    /////////////////////////////////////////////////////*/

    /**
     *
     * @notice follows CEI
     * @param tokenCollateral address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateral] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateral, amountCollateral);

        bool success = IERC20(tokenCollateral).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    
    //Check if the collateral value is greater than the DSC amount
    /**
     * @notice follows CEI
     * @param amountToMint  The amount of decentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) nonReentrant {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateral, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*/////////////////////////////////////////////////////
    //////////         PRIVATE FUNCTIONS         //////////
    /////////////////////////////////////////////////////*/
     /**
     *
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBeHalfOf, address dscFrom) private {
        s_DSCMinted[onBeHalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateral, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateral] -= amountCollateral;

        bool success = IERC20(tokenCollateral).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*/////////////////////////////////////////////////////
    //////////       PUBLIC VIEW FUNCTIONS       //////////
    /////////////////////////////////////////////////////*/
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountValueInUsd(address user) public view returns (uint256 collateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            collateralValueInUsd += getUsdValue(token, amount);
        }
        return collateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 amountUsdInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (amountUsdInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /*/////////////////////////////////////////////////////
    //////////       INTERNAL VIEW FUNCTIONS     //////////
    /////////////////////////////////////////////////////*/
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroke(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 amountCollateral) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (amountCollateral * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

         /**
         * Example:
         * e.1. $1000 ETH * 50 = 50,000 / 100 = 500
         * e.2. $150 ETH * $50 DSC = 7500 / 100 = 75 (75 / 100) < 1
         * e.3. we have $1000 ETH and $100 DSC:
         *      1000 * 50 = 50,000 / 100 = (500 / 100) > 1
         */
    }

    /*/////////////////////////////////////////////////////
    //////////       PRIVATE VIEW FUNCTIONS      //////////
    /////////////////////////////////////////////////////*/

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 amountCollateral)
    {
        totalDscMinted = s_DSCMinted[user];
        amountCollateral = getAccountValueInUsd(user);
    }

    /**
     *  Returns how close to liquidation a user is
     *  If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 amountCollateral) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, amountCollateral);
    }

    /*/////////////////////////////////////////////////////
    //////////          GETTER FUNCTIONS         //////////
    /////////////////////////////////////////////////////*/
    function getTokenCollateralAddresses() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getPriceFeedAddresses(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralDeposited(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getDSC() external view returns (address) {
        return address(i_dsc);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user) external view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256){
        return _healthFactor(user);
    }
}
