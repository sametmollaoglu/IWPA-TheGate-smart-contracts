// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/Vesting.sol";

//seed sale flag => 0
//private sale flag => 1

contract Crowdsale is ReentrancyGuard, Ownable, Vesting {
    using SafeMath for uint256;

    // Address where funds are collected as USDT
    address payable public usdtWallet;

    ICOdata[] private ICOdatas;

    uint256 private totalAllocation;
    uint256 private totalLeftover;

    mapping(uint256 => mapping(address => bool)) private whitelist;
    mapping(address => mapping(uint256 => bool)) private isIcoMember;
    mapping(uint256 => address[]) private icoMembers;

    IERC20 public usdt = IERC20(0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8);
    IERC20 public tenet;

    //State of ICO sales
    enum IcoState {
        active,
        onlyWhitelist,
        nonActive,
        done
    }

    struct ICOdata {
        string ICOname;
        //Supply of the ICO
        uint256 ICOsupply;
        // Amount of usdt raised
        uint256 ICOusdtRaised;
        //Total amount of allocated tokens
        uint256 ICOtokenAllocated;
        //Total amount of sold tokens
        uint256 ICOtokenSold;
        //State of the ICO
        IcoState ICOstate;
        //Number of cliff months
        uint256 ICOnumberOfCliff;
        //Number of vesting months
        uint256 ICOnumberOfVesting;
        //Unlock rate of the ICO sale
        uint256 ICOunlockRate;
        uint256 ICOstartDate;
        uint256 TokenAbsoluteUsdtPrice;
    }

    //Checks whether the specific ICO sale is active or not
    modifier isIcoAvailable(uint256 _icoType) {
        require(ICOdatas[_icoType].ICOstartDate != 0, "ico does not exist !");
        require(
            ICOdatas[_icoType].ICOstate != IcoState.nonActive,
            "ICO is not active."
        );
        if (ICOdatas[_icoType].ICOstate == IcoState.onlyWhitelist) {
            require(whitelist[_icoType][msg.sender], "Member not in whitelist");
        }
        _;
    }

    event priceChanged(string ICOname, uint256 oldPrice, uint256 newPrice);

    /**
     * @param _token Address of the token being sold (token contract).
     * @param _usdtWallet Address where collected funds will be forwarded to.
     */
    constructor(address _token, address payable _usdtWallet) Vesting(_token) {
        require(
            address(_token) != address(0),
            "ERROR at Crowdsale constructor: Token contract shouldn't be zero address."
        );
        require(
            _usdtWallet != address(0),
            "ERROR at Crowdsale constructor: USDT wallet shouldn't be zero address."
        );

        token = ERC20(_token);
        usdtWallet = _usdtWallet;
        totalAllocation = 0;
    }

    /*
     * @param _rate How many token units a buyer gets per USDT at seed sale.
     * @param _supply Number of token will be in seed sale.
     * @param _cliffMonths Number of cliff months of seed sale.
     * @param _vestingMonths Number of vesting months of seed sale.
     * @param _unlockRate Unlock rate of the seed sale.
     */
    function createICO(
        string memory _name,
        uint256 _supply,
        uint256 _cliffMonths,
        uint256 _vestingMonths,
        uint8 _unlockRate,
        uint256 _startDate,
        uint256 _tokenAbsoluteUsdtPrice
    ) external onlyOwner {
        require(
            _tokenAbsoluteUsdtPrice > 0,
            "ERROR at Crowdsale constructor: Token price for seed sale should be bigger than zero."
        );
        require(
            _supply > 0,
            "ERROR at Crowdsale constructor: Supply for seed sale should be bigger than zero."
        );
        require(
            _startDate >= block.timestamp,
            "Start date must be greater than now"
        );
        require(
            totalAllocation + _supply <= token.balanceOf(msg.sender),
            "ERROR at createICO: Cannot create sale round because not sufficient tokens."
        );
        totalAllocation += _supply;

        ICOdatas.push(
            ICOdata({
                ICOname: _name,
                ICOsupply: _supply,
                ICOusdtRaised: 0,
                ICOtokenAllocated: 0,
                ICOtokenSold: 0,
                ICOstate: IcoState.nonActive,
                ICOnumberOfCliff: _cliffMonths,
                ICOnumberOfVesting: _vestingMonths,
                ICOunlockRate: _unlockRate,
                ICOstartDate: _startDate,
                TokenAbsoluteUsdtPrice: _tokenAbsoluteUsdtPrice
            })
        );
    }

    /**
     * @dev Client function. Buyer can buy tokens and became participant of own vesting schedule.
     * @param _icoType To specify type of the ICO sale.
     */
    function buyTokens(uint256 _icoType, uint256 usdtAmount)
        public
        nonReentrant
        isIcoAvailable(_icoType)
    {
        ICOdata memory ico = ICOdatas[_icoType];

        address beneficiary = msg.sender;
        require(ico.ICOstartDate >= block.timestamp, "ICO date expired");

        uint256 tokenAmount = _getTokenAmount(
            usdtAmount,
            ico.TokenAbsoluteUsdtPrice
        );

        _preValidatePurchase(beneficiary, tokenAmount, _icoType);

        if (
            vestingSchedules[beneficiary][_icoType].beneficiaryAddress ==
            address(0x0)
        ) {
            createVestingSchedule(
                beneficiary,
                ico.ICOnumberOfCliff,
                ico.ICOnumberOfVesting,
                ico.ICOunlockRate,
                true,
                tokenAmount,
                _icoType,
                usdtAmount,
                ico.ICOstartDate,
                ico.TokenAbsoluteUsdtPrice
            );
        } else {
            uint256 totalVestingAllocation = (tokenAmount -
                (ico.ICOunlockRate * tokenAmount) /
                100);
            vestingSchedules[beneficiary][_icoType]
                .cliffAndVestingAllocation += tokenAmount;
            vestingSchedules[beneficiary][_icoType]
                .vestingAllocation += totalVestingAllocation;
            vestingSchedules[beneficiary][_icoType].investedUSDT += usdtAmount;
        }

        _updatePurchasingState(usdtAmount, tokenAmount, _icoType);
        _forwardFunds(usdtAmount);
        if (isIcoMember[beneficiary][_icoType] == false) {
            isIcoMember[beneficiary][_icoType] = true;
            icoMembers[_icoType].push(beneficiary);
        }
    }

    /**
     * @dev Client function. Buyer can claim vested tokens according to own vesting schedule.
     * @param _icoType To specify type of the ICO sale.
     */
    function claimAsToken(uint256 _icoType)
        public
        nonReentrant
        isIcoAvailable(_icoType)
    {
        address beneficiary = msg.sender;
        ICOdatas[_icoType].ICOtokenSold += viewReleasableAmount(
            beneficiary,
            _icoType
        );
        _processPurchaseToken(beneficiary, _icoType);
    }

    /**
     * @dev Client function. Buyer can withdraw all of the invested USDT amount instead of tokens and his/her schedule will be cancelled.
     * @param _icoType To specify type of the ICO sale.
     */
    function claimAsUsdt(uint256 _icoType)
        public
        nonReentrant
        isIcoAvailable(_icoType)
    {
        address beneficiary = msg.sender;
        uint256 releasableUsdtAmount = getReleasableUsdtAmount(
            beneficiary,
            _icoType
        );
        require(
            releasableUsdtAmount > 0,
            "ERROR at claimAsUsdt: Releasable USDT amount is 0."
        );
        _processPurchaseUSDT(beneficiary, releasableUsdtAmount);
        ICOdatas[_icoType].ICOusdtRaised -= releasableUsdtAmount;

        //tether alıyor token sayımızı arttırıyor çünkü geri veriyor
        ICOdatas[_icoType].ICOtokenAllocated -= (releasableUsdtAmount /
            ICOdatas[_icoType].TokenAbsoluteUsdtPrice);
    }

    /**
     * @dev Validation of an incoming purchase request. Use require statements to revert state when conditions are not met.
     * @param _beneficiary Address performing the token purchase
     * @param _tokenAmount Token amount that beneficiary can buy
     * @param _icoType To specify type of the ICO sale.
     */
    function _preValidatePurchase(
        address _beneficiary,
        uint256 _tokenAmount,
        uint256 _icoType
    ) internal view {
        require(_beneficiary != address(0));
        require(
            _tokenAmount > 0,
            "You need to send at least some USDT to buy tokens."
        );
        require(
            ICOdatas[_icoType].ICOtokenAllocated + _tokenAmount <=
                ICOdatas[_icoType].ICOsupply,
            "Not enough token in the ICO supply"
        );
        //require(usdt.balanceOf(_beneficiary)>=_usdtAmount,"Not enough USDT");
    }

    /**
     * @dev Beneficiary can claim own vested tokens.
     * @param _beneficiary Address receiving the tokens.
     * @param _icoType To specify type of the ICO sale.
     */
    function _processPurchaseToken(address _beneficiary, uint256 _icoType)
        internal
    {
        release(_beneficiary, _icoType);
    }

    /**
     * @dev Beneficiary can withdraw exactly amount of deposited USDT investing.
     */
    function _processPurchaseUSDT(address beneficiary, uint256 releasableUsdt)
        internal
    {
        usdt.transferFrom(usdtWallet, beneficiary, releasableUsdt);
        //kullanıcı her tutar claim edeceğinde wallettan onay beklemesi gerek.walletı contract yapabiliriz?
    }

    /**
     * @dev Update current beneficiary contributions to the ICO sale.
     * @param _usdtAmount Value in USDT involved in the purchase.
     * @param _tokenAmount Number of tokens to be purchased.
     * @param _icoType To specify type of the ICO sale.
     */
    function _updatePurchasingState(
        uint256 _usdtAmount,
        uint256 _tokenAmount,
        uint256 _icoType
    ) internal {
        ICOdata storage ico = ICOdatas[_icoType];
        ico.ICOtokenAllocated += _tokenAmount;
        ico.ICOusdtRaised += _usdtAmount;
    }

    /**
     * @dev Returns token amount of the USDT investing.
     * @param _usdtAmount Value in USDT to be converted into tokens.
     * @param _absoluteUsdtPrice Absolute usdt value of token (Actual token price * 10**6)
     * @return Number of tokens that can be purchased with the specified _usdtAmount.
     */
    function _getTokenAmount(uint256 _usdtAmount, uint256 _absoluteUsdtPrice)
        internal
        pure
        returns (uint256)
    {
        _usdtAmount = _usdtAmount * (10**6);
        _usdtAmount = _usdtAmount.div(_absoluteUsdtPrice);
        return _usdtAmount;
    }

    /**
     * @dev Determines how USDT is stored/forwarded on purchases.
     */
    function _forwardFunds(uint usdtAmount) internal {
        //usdt number of decimal is 6
        usdt.transferFrom(msg.sender, usdtWallet, usdtAmount);
    }

    /**
     * @dev Withdraw allowance amounts to the wallet.
     */
    function _withdrawFunds() external onlyOwner {
        //withdraw allowances of beneficiaries investments to the wallet (after finish of the ICO)
    }

    /**
     * @dev Change ICO state, can start or end ICO sale.
     * @param _icoType ICO type value to specify sale.
     */
    function changeIcoState(uint256 _icoType, IcoState icoState)
        external
        onlyOwner
    {
        ICOdatas[_icoType].ICOstate = icoState;
        if (icoState == IcoState.done) {
            totalLeftover += (ICOdatas[_icoType].ICOsupply -
                ICOdatas[_icoType].ICOtokenAllocated);
        }
    }

    function increaseIcoSupplyWithLeftover(uint256 _icoType, uint256 amount)
        external
        onlyOwner
    {
        require(ICOdatas[_icoType].ICOstartDate != 0, "ico does not exist !");
        require(ICOdatas[_icoType].ICOstate != IcoState.done, "ICO is done.");
        require(totalLeftover >= amount, "Not enough leftover");
        ICOdatas[_icoType].ICOsupply += amount;
        totalLeftover -= amount;
    }

    function getLeftover()
        external
        view
        // totalLeftover can be public maybe
        onlyOwner
        returns (uint256)
    {
        return totalLeftover;
    }

    /*
     * @notice Owner can add an address to whitelist.
     * @param _beneficiary Address of the beneficiary.
     * @param _icoType ICO type value to specify sale.
     */

    function addToWhitelist(address _beneficiary, uint256 _icoType)
        external
        onlyOwner
    {
        whitelist[_icoType][_beneficiary] = true;
    }

    function getICOMembers(uint256 _icoType)
        external
        view
        onlyOwner
        returns (address[] memory)
    {
        return icoMembers[_icoType];
    }

    /**
     * @dev Owner function. Change usdt wallet address.
     * @param _usdtWalletAddress New USDT wallet address.
     */

    function changeUSDTWalletAddress(address payable _usdtWalletAddress)
        public
        onlyOwner
    {
        require(
            _usdtWalletAddress != address(0),
            "ERROR at Crowdsale changeUSDTAddress: USDT wallet address shouldn't be zero address."
        );
        usdtWallet = _usdtWalletAddress;
    }

    /**
     * @dev Owner function. Change tenet contract address.
     * @param _tenetAddress New tenet contract address.
     */
    function setTenetContract(address _tenetAddress) external onlyOwner {
        require(
            _tenetAddress != address(0),
            "ERROR at Crowdsale setTenetContract: Tenet contract address shouldn't be zero address."
        );
        tenet = IERC20(_tenetAddress);
    }

    /**
     * @dev Owner function. Change IWPA token contract address.
     * @param _tokenAddress New IWPA token contract address.
     */
    function setTokenContract(address _tokenAddress) external onlyOwner {
        require(
            _tokenAddress != address(0),
            "ERROR at Crowdsale setTokenContract: IWPA Token contract address shouldn't be zero address."
        );
        token = ERC20(_tokenAddress);
    }

    struct VestingScheduleData {
        uint id;
        uint unlockDateTimestamp;
        uint tokenAmount;
        uint usdtAmount;
        uint vestingRate;
    }

    function getVestingList(uint icoType)
        public
        view
        returns (VestingScheduleData[] memory)
    {
        ICOdata memory data = ICOdatas[icoType];
        require(data.TokenAbsoluteUsdtPrice != 0, "ICO doesn not exist");
        uint size = data.ICOnumberOfVesting + 1;
        VestingScheduleData[] memory scheduleArr = new VestingScheduleData[](
            size
        );
        VestingScheduleStruct memory vesting = getBeneficiaryVesting(
            msg.sender,
            icoType
        );

        uint cliffTokenAllocation = (vesting.cliffAndVestingAllocation *
            vesting.unlockRate) / 100;
        uint cliffUsdtAllocation = (cliffTokenAllocation *
            data.TokenAbsoluteUsdtPrice) / 10**6;
        uint cliffUnlockDateTimestamp = vesting.initializationTime +
            (vesting.numberOfCliff * 30 days);
        scheduleArr[0] = VestingScheduleData({
            id: 0,
            unlockDateTimestamp: cliffUnlockDateTimestamp,
            tokenAmount: cliffTokenAllocation,
            usdtAmount: cliffUsdtAllocation,
            vestingRate: vesting.unlockRate
        });

        uint vestingRateAfterCliff = (100 - vesting.unlockRate) /
            vesting.numberOfVesting;

        uint usdtAmountAfterCliff = (vesting.investedUSDT -
            cliffUsdtAllocation) / data.ICOnumberOfVesting;
        uint tokenAmountAfterCliff = vesting.vestingAllocation /
            data.ICOnumberOfVesting;

        for (uint i = 0; i < vesting.numberOfVesting; ++i) {
            cliffUnlockDateTimestamp += 30 days;
            scheduleArr[i + 1] = VestingScheduleData({
                id: i + 1,
                unlockDateTimestamp: cliffUnlockDateTimestamp,
                tokenAmount: tokenAmountAfterCliff,
                usdtAmount: usdtAmountAfterCliff,
                vestingRate: vestingRateAfterCliff
            });
        }
        return scheduleArr;
    }

    function getICODatas() external view onlyOwner returns (ICOdata[] memory) {
        return ICOdatas;
    }

    function changeAbsoluteTokenUsdtPrice(
        uint256 _newTokenPrice,
        uint256 _icoType
    ) external onlyOwner {
        ICOdata storage data = ICOdatas[_icoType];
        uint256 oldPrice = data.TokenAbsoluteUsdtPrice;
        data.TokenAbsoluteUsdtPrice = _newTokenPrice;
        emit priceChanged(data.ICOname, oldPrice, _newTokenPrice);
    }
}
