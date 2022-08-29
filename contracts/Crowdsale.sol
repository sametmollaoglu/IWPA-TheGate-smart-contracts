// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
contract Crowdsale is ReentrancyGuard{
  using SafeMath for uint256;

  // The IWPA token contract
  IERC20 public token;

  // Address where funds are collected
  address payable public wallet;

  // How many token units a buyer gets per usdt
  uint256 public rate;

  // Amount of usdt raised
  uint256 public usdtRaised;

  //Total ICO supply
  uint256 public supply;

  //Total amount of allocated tokens
  uint256 public tokenAllocated;

  //Total amount of sold tokens
  uint256 public tokenSold;
  
  //ICO start date
  uint256 public start;

  //ICO end date
  uint256 public end;


  modifier isIcoActive() {
        require(block.timestamp >= start && block.timestamp <= end, "ICO should be active.");
        _;
  }
  modifier isIcoFinished() {
        require(block.timestamp >= end, "ICO is not finished yet.");
        _;
  }

  //Beneficiary addresses and their balances
  mapping(address => uint256) earnedTokenBalance;

  //Beneficiary addresses and their investments
  mapping(address => uint256) investedUSDT;
  
  //Shows whether assigned tokens is claimed or not
  mapping(address => bool) Claimed;

  /**
   * Event for token purchase logging
   * @param purchaser who paid for the tokens
   * @param beneficiary who got the tokens
   * @param value USDT paid for purchase
   * @param amount amount of tokens purchased
   */
  event TokenDelivered(
    address indexed purchaser,
    address indexed beneficiary,
    uint256 value,
    uint256 amount
  );

  /**
   * Event for USDT withdraw back
   * @param purchaser who paid for the tokens
   * @param beneficiary who got the USDT investment back
   * @param value amount of USDT invested
   */
  event UsdtDelivered(
    address indexed purchaser,
    address indexed beneficiary,
    uint256 value
  );

  /**
   * @param _token Address of the token being sold (token contract).
   * @param _wallet Address where collected funds will be forwarded to.
   * @param _rate How many token units a buyer gets per usdt.
   * @param _supply Number of token will be in that round.
   * @param _start ICO start date
   * @param _end ICO end date
   */
  constructor(IERC20 _token, address payable _wallet,
  uint256 _rate,uint256 _supply, uint256 _start,uint256 _end) {

    require(address(_token) != address(0),"ERROR at Crowdsale constructor: Token contract shouldn't be zero address.");
    require(_wallet != address(0),"ERROR at Crowdsale constructor: Wallet shouldn't be zero address.");
    require(_rate > 0,"ERROR at Crowdsale constructor: Rate should be bigger than zero.");
    require(_supply > 0,"ERROR at Crowdsale constructor: Supply should be bigger than zero.");
    require(_start > 0,"ERROR at Crowdsale constructor: Please give correct start date.");
    require(_end > _start,"ERROR at Crowdsale constructor: Please give correct end date.");

    token = IERC20(_token);
    wallet = _wallet;
    rate=_rate;
    usdtRaised=0;
    supply=_supply;
    tokenSold=0;
    start=_start;
    end=_end;
  }

  /**
   * @dev fallback function ***DO NOT OVERRIDE***
   */
  receive() external payable {
    buyTokens();
  }


  function buyTokens() public payable nonReentrant isIcoActive{
    address beneficiary = msg.sender;
    uint256 usdtAmount = msg.value;
    uint256 tokenAmount = _getTokenAmount(usdtAmount);

    _preValidatePurchase(beneficiary, tokenAmount);
    _updatePurchasingState(beneficiary, usdtAmount,tokenAmount);
    _forwardFunds();
  }

  function claimAsToken() public nonReentrant isIcoFinished{
    address beneficiary = msg.sender;
    _processPurchaseToken(beneficiary, earnedTokenBalance[beneficiary]);
    emit TokenDelivered(beneficiary,beneficiary,investedUSDT[beneficiary],earnedTokenBalance[beneficiary]);
    tokenAllocated-=earnedTokenBalance[beneficiary];
    tokenSold+=earnedTokenBalance[beneficiary];
    _postValidatePurchase(beneficiary);
  }

  function claimAsUsdt() public nonReentrant isIcoFinished{
    address beneficiary = msg.sender;
    _processPurchaseUSDT(beneficiary, investedUSDT[beneficiary]);
    emit UsdtDelivered(beneficiary,beneficiary,investedUSDT[beneficiary]);
    tokenAllocated-=earnedTokenBalance[beneficiary];
    usdtRaised-=investedUSDT[beneficiary];
    _postValidatePurchase(beneficiary);
  }

  /**
   * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met. Use super to concatenate validations.
   * @param _beneficiary Address performing the token purchase
   * @param _tokenAmount Token amount that beneficiary can buy
   */
  function _preValidatePurchase(
    address _beneficiary,
    uint256 _tokenAmount
  )
    internal
    view
  {
    require(_beneficiary != address(0));
    require(_tokenAmount > 0, "You need to send at least some USDT to buy tokens.");
    require(tokenAllocated + _tokenAmount <= supply, "Not enough token in the supply");
  }

  /**
   * @dev Executed when a purchase has been validated and sends its tokens.
   * @param _beneficiary Address receiving the tokens
   * @param _tokenAmount Number of tokens to be purchased
   */
  function _processPurchaseToken(
    address _beneficiary,
    uint256 _tokenAmount
  )
    internal
  {
    token.transfer(_beneficiary, _tokenAmount);
  }

  /**
   * @dev Executed when a purchase has been validated but sends USDT amount instead of tokens.
   * @param _beneficiary Address withdraw the USDT
   * @param _USDTamount Amount of USDT to be withdraw
   */
  function _processPurchaseUSDT(
    address _beneficiary,
    uint256 _USDTamount
  )
    internal
  {
    //USDT transfer back to the beneficiary account
  }

  /**
   * @dev Override for extensions that require an internal state to check for validity (current user contributions, etc.)
   * @param _beneficiary Address receiving the tokens
   * @param _usdtAmount Value in USDT involved in the purchase
   * @param _tokenAmount Number of tokens to be purchased
   */
  function _updatePurchasingState(
    address _beneficiary,
    uint256 _usdtAmount,
    uint256 _tokenAmount
  )
    internal
  {
    tokenAllocated+=_tokenAmount;
    Claimed[_beneficiary]=false;
    earnedTokenBalance[_beneficiary]+=_tokenAmount;
    investedUSDT[_beneficiary]+=_usdtAmount;
    usdtRaised +=_usdtAmount;
  }

  /**
   * @dev Following processes of claiming. Just for resetting the beneficiary state.
   * @param _beneficiary Address performing the token purchase
   */
  function _postValidatePurchase(
    address _beneficiary
  )
    internal
  {
    Claimed[_beneficiary]=true;
    earnedTokenBalance[_beneficiary]=0;
    investedUSDT[_beneficiary]=0;
  }

  /**
   * @dev Override to extend the way in which USDT is converted to tokens.
   * @param _usdtAmount Value in USDT to be converted into tokens
   * @return Number of tokens that can be purchased with the specified _usdtAmount
   */
  function _getTokenAmount(uint256 _usdtAmount)
    internal view returns (uint256)
  {
    return _usdtAmount.mul(rate);
  }

  /**
   * @dev Determines how USDT is stored/forwarded on purchases.
   */
  function _forwardFunds() internal {
    payable(wallet).transfer(msg.value);
  }
}