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

    mapping(uint256 => mapping(address => bool)) private whitelist;
    mapping(address => mapping(uint256 => bool)) private isIcoMember;
    mapping(uint256 => address[]) private icoMembers;

    IERC20 public usdt = IERC20(0xbA6879d0Df4b09fC678Ca065c00dd345AdF0365e); //test tether
    IERC20 public tenet;
    //State of ICO sales
    enum IcoState {
        active,
        onlyWhitelist,
        nonActive
    }

    struct ICOdata {
        string ICOname;
        // How many token units a buyer gets per USDT
        uint256 ICOrate;
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

        token = IERC20(_token);
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
        uint256 _rate,
        uint256 _supply,
        uint256 _cliffMonths,
        uint256 _vestingMonths,
        uint8 _unlockRate,
        uint256 _startDate
    ) external onlyOwner {
        require(
            _rate > 0,
            "ERROR at Crowdsale constructor: Rate for seed sale should be bigger than zero."
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

        uint _usdtRate = _rate * 10**18;
        ICOdatas.push(
            ICOdata({
                ICOname: _name,
                ICOrate: _usdtRate,
                ICOsupply: _supply,
                ICOusdtRaised: 0,
                ICOtokenAllocated: 0,
                ICOtokenSold: 0,
                ICOstate: IcoState.nonActive,
                ICOnumberOfCliff: _cliffMonths,
                ICOnumberOfVesting: _vestingMonths,
                ICOunlockRate: _unlockRate,
                ICOstartDate: _startDate
            })
        );
    }

    /**
     * @dev Client function. Buyer can buy tokens and became participant of own vesting schedule.
     * @param _icoType To specify type of the ICO sale.
     */
    function buyTokens(uint256 _icoType, uint256 usdtAmount)
        public
        //payable
        nonReentrant
        isIcoAvailable(_icoType)
    {
        ICOdata memory ico = ICOdatas[_icoType];

        address beneficiary = msg.sender;
        require(ico.ICOstartDate >= block.timestamp, "ICO date expired");

        uint256 tokenAmount = _getTokenAmount(usdtAmount, ico.ICOrate);

        _preValidatePurchase(beneficiary, tokenAmount, _icoType);
        createVestingSchedule(
            beneficiary,
            ico.ICOnumberOfCliff,
            ico.ICOnumberOfVesting,
            ico.ICOunlockRate,
            true,
            tokenAmount,
            _icoType,
            usdtAmount,
            ico.ICOstartDate
        );
        _updatePurchasingState(usdtAmount, tokenAmount, _icoType);
        _forwardFunds(usdtAmount);
        if (isIcoMember[beneficiary][_icoType] == false) {
            isIcoMember[beneficiary][_icoType] = true;
            icoMembers[_icoType].push(beneficiary);
        }

        /* eth gelirse contractta parası kalıyor ve teth olarak da ayrıca transfer ediliyor
        uint balance = address(this).balance;
        (beneficiary.call{value: balance}("")
        */
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
        ICOdatas[_icoType].ICOtokenSold += getReleasableAmount(
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
        uint releasableUsdtAmount = getReleasableUsdtAmount(
            beneficiary,
            _icoType
        );
        _processPurchaseUSDT(releasableUsdtAmount, beneficiary);
        ICOdatas[_icoType].ICOusdtRaised -= releasableUsdtAmount;

        //tether alıyor token sayımızı arttırıyor çünkü geri veriyor
        ICOdatas[_icoType].ICOtokenAllocated -= getReleasableAmount(
            beneficiary,
            _icoType
        );
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
    function _processPurchaseUSDT(uint releasedUsdt, address beneficiary)
        internal
    {
        usdt.approve(beneficiary, releasedUsdt);
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
     * @param _ICOrate Seed or private ICO rate.
     * @return Number of tokens that can be purchased with the specified _usdtAmount.
     */
    function _getTokenAmount(uint256 _usdtAmount, uint256 _ICOrate)
        internal
        pure
        returns (uint256)
    {
        return _usdtAmount.div(_ICOrate);
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
    }

    /**
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
     * @dev Owner function. Change usdt contract address.
     * @param _usdtContractAddress New USDT contract address.
     */
    function changeUSDTContractAddress(address _usdtContractAddress)
        public
        onlyOwner
    {
        require(
            _usdtContractAddress != address(0),
            "ERROR at Crowdsale changeUSDTAddress: USDT contract address shouldn't be zero address."
        );
        usdt = IERC20(_usdtContractAddress);
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
        onlyOwner
        returns (VestingScheduleData[] memory)
    {
        ICOdata memory data = ICOdatas[icoType];
        require(data.ICOrate != 0, "ICO doesn not exist");
        uint size = data.ICOnumberOfVesting + 1;
        VestingScheduleData[] memory scheduleArr = new VestingScheduleData[](
            size
        );
        VestingScheduleStruct memory vesting = getBeneficiaryVesting(
            msg.sender,
            icoType
        );

        uint cliffTokenAllocation = ((vesting.cliffAndVestingAllocation *
            (10**18)) * vesting.unlockRate) / 100; //wei
        //uint cliffUsdtAllocation = (cliffTokenAllocation * vesting.investedUSDT) / (vesting.cliffAndVestingAllocation * (10**18)); //wei
        uint cliffUsdtAllocation = cliffTokenAllocation *
            (data.ICOrate / (10**18)); //wei
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
        uint usdtAmountAfterCliff = (data.ICOusdtRaised - cliffUsdtAllocation) /
            data.ICOnumberOfVesting; //wei
        uint tokenAmountAfterCliff = ((data.ICOtokenAllocated * (10**18)) -
            cliffTokenAllocation) / data.ICOnumberOfVesting; //wei
        //uint usdtAmountAfterCliff = ((vesting.vestingAllocation * (10**18) ) * vesting.investedUSDT) / vesting.numberOfVesting; //wei
        //uint tokenAmountAfterCliff = (vesting.vestingAllocation * (10**18) ) / vesting.numberOfVesting; //wei

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

    function setTenetContract(address tenetAddress) external onlyOwner {
        tenet = IERC20(tenetAddress);
    }
}
