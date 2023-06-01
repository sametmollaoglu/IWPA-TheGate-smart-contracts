// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IVesting {
    struct VestingScheduleStruct {
        address beneficiaryAddress;
        uint256 icoStartDate;
        uint256 numberOfCliff;
        uint256 numberOfVesting;
        uint256 unlockRate;
        bool revoked;
        uint256 cliffAndVestingAllocation;
        uint256 vestingAllocation;
        uint256 claimedTokenAmount;
        bool tgeVested;
        uint256 releasedPeriod;
        uint256 icoType;
        uint256 investedUSDT;
    }

    function getBeneficiaryVesting(address beneficiary, uint256 icoType)
        external 
        view
        returns (VestingScheduleStruct memory);

    function createVestingSchedule(
        address _beneficiary,
        uint256 _numberOfCliffMonths,
        uint256 _numberOfVestingMonths,
        uint256 _unlockRate,
        uint256 _allocation,
        uint256 _IcoType,
        uint256 _investedUsdt,
        uint256 _icoStartDate
    ) external;

    function vestingRevocation(
        address _beneficiary, 
        uint256 _icoType,
        uint256 notVestedTokenAllocation
    ) external;

    function updateBuyTokens(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAmount,
        uint256 _totalVestingAllocation,
        uint256 _usdtAmount
    ) external;

    function getReleasableAmount(address _beneficiary, uint256 _icoType)
        external
        returns (uint256);
    
}

contract Crowdsale is Ownable {

    // Address where funds are collected as USDT
    address payable public usdtWallet;

    ERC20 public token;
    
    //usdt contract address
    IERC20 public usdt = IERC20(0x4C5DA3bF8A975D523baca06EeC71a24F8B9752DB);

    IVesting vestingContract;
    ICOdata[] private ICOdatas;

    uint256 private totalAllocation;
    uint256 private totalLeftover;

    mapping(uint256 => mapping(address => bool)) private whitelist;
    mapping(address => mapping(uint256 => bool)) private isIcoMember;
    mapping(uint256 => address[]) private icoMembers;
    
/*
* @EVENTS  
*/
//////////////////////////////////////////////////////////////////////////////////////////
    event processPurchaseTokenEvent(
        address _beneficiary,
        uint256 _icoType,
        uint256 releasedAmount
    );

    event priceChanged(string ICOname, uint256 oldPrice, uint256 newPrice);

    event createICOEvent(uint256 totalTokenAllocation, uint256 ICOsupply, uint256 totalTokenSupply);

    event updatePurchasingStateEvent(uint256 _icoType, string ICOname, uint256 ICOsupply, uint256 newICOtokenAllocated, uint256 tokenAmount, uint256 newICOusdtRaised, uint256 usdtAmount);
//////////////////////////////////////////////////////////////////////////////////////////

/*
* @MODIFIERS
*/
//////////////////////////////////////////////////////////////////////////////////////////

    //Checks whether the specific ICO sale is active or not
    modifier isSaleAvailable(uint256 _icoType) {
        ICOdata memory ico = ICOdatas[_icoType];
        require(ico.ICOstartDate != 0, "Ico does not exist !");
        require(
            ico.ICOstartDate >= block.timestamp,
            "ICO date expired."
        );
        require(
            ico.ICOstate == IcoState.active || ico.ICOstate == IcoState.onlyWhitelist,
            "Sale not available"
        );
        if (ico.ICOstate == IcoState.onlyWhitelist) {
            require(whitelist[_icoType][msg.sender], "Member is not in the whitelist");
        }
        _;
    }

    //Checks whether the specific sale is available or not
    modifier isClaimAvailable(uint256 _icoType) {
        ICOdata memory ico = ICOdatas[_icoType];

        require(ico.ICOstartDate != 0, "Ico does not exist !");
        
        require(
            ico.ICOstate != IcoState.nonActive,
            "Claim is currently stopped."
        );
        _;
    }

//////////////////////////////////////////////////////////////////////////////////////////

    //State of ICO sales
    enum IcoState {
        active,
        onlyWhitelist,
        nonActive,
        done
    }

    struct ICOdata {
        string ICOname;
        uint256 ICOsupply;
        uint256 ICOusdtRaised;
        uint256 ICOtokenAllocated;
        //total token claimed by beneficiaries
        uint256 ICOtokenSold;
        IcoState ICOstate;
        uint256 ICOnumberOfCliff;
        uint256 ICOnumberOfVesting;
        uint256 ICOunlockRate;
        uint256 ICOstartDate;
        //Absolute token price (tokenprice(USDT) * (10**6))
        uint256 TokenAbsoluteUsdtPrice;
        //If the team vesting data, should be free participation vesting for only to specific addresses
        uint256 IsFree;
    }

    struct VestingScheduleData {
        uint256 id;
        uint256 unlockDateTimestamp;
        uint256 tokenAmount;
        uint256 usdtAmount;
        uint256 vestingRate;
        bool collected;
    }

    /**
     * @param _token Address of the token being sold (token contract).
     * @param _usdtWallet Address where collected funds will be forwarded to.
     * @param _vestingContract Vesting contract address.
     */
    constructor(
        address _token,
        address payable _usdtWallet,
        address _vestingContract
    ) {
        require(
            address(_token) != address(0),
            "ERROR at Crowdsale constructor: Token contract address shouldn't be zero address."
        );
        require(
            _usdtWallet != address(0),
            "ERROR at Crowdsale constructor: USDT wallet address shouldn't be zero address."
        );
        require(
            _vestingContract != address(0),
            "ERROR at Crowdsale constructor: Vesting contract address shouldn't be zero address."
        );

        token = ERC20(_token);
        usdtWallet = _usdtWallet;
        totalAllocation = 0;
        vestingContract = IVesting(_vestingContract);
    }

    receive() external payable {}

    fallback() external payable {}

    function createICO(
        string calldata _name,
        uint256 _supply,
        uint256 _cliffMonths,
        uint256 _vestingMonths,
        uint8 _unlockRate,
        uint256 _startDate,
        uint256 _tokenAbsoluteUsdtPrice, //Absolute token price (tokenprice(USDT) * (10**6)), 0 if free
        uint256 _isFree //1 if free, 0 if not-free
    ) external onlyOwner {
        if (_isFree==0) {
            require(
                _tokenAbsoluteUsdtPrice > 0,
                "ERROR at createICO: Token price should be bigger than zero."
            );
        }
        require(
            _startDate >= block.timestamp,
            "ERROR at createICO: Start date must be greater than now."
        );
        require(
            totalAllocation + _supply <= (token.balanceOf(msg.sender)/(10**token.decimals())),
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
                TokenAbsoluteUsdtPrice: _tokenAbsoluteUsdtPrice,
                IsFree: _isFree
            })
        );
        emit createICOEvent(totalAllocation,_supply,token.balanceOf(msg.sender));
    }

    /**
     * @dev Client function. Buyer can buy tokens and personalized vesting schedule is created.
     * @param _icoType Ico type  ex.: 0=>seed, 1=>private
     * @param _usdtAmount Amount of invested USDT
     */
    function buyTokens(uint256 _icoType, uint256 _usdtAmount)
        public 
        isSaleAvailable(_icoType)
    {
        ICOdata memory ico = ICOdatas[_icoType];
        address beneficiary = msg.sender;

        require(
            ico.IsFree == 0,
            "ERROR at buyTokens: This token distribution is exclusive to the team only."
        );

        uint256 tokenAmount = _getTokenAmount(
            _usdtAmount,
            ico.TokenAbsoluteUsdtPrice
        );

        _preValidatePurchase(beneficiary, tokenAmount, _icoType);

        if (
            vestingContract
                .getBeneficiaryVesting(beneficiary, _icoType)
                .beneficiaryAddress == address(0x0)
        ) {
            vestingContract.createVestingSchedule(
                beneficiary,
                ico.ICOnumberOfCliff,
                ico.ICOnumberOfVesting,
                ico.ICOunlockRate,
                tokenAmount,
                _icoType,
                _usdtAmount,
                ico.ICOstartDate
            );
        } else {

            require(
                !vestingContract
                    .getBeneficiaryVesting(beneficiary, _icoType)
                    .revoked,
                "ERROR at additional buyTokens: Vesting Schedule is revoked."
            );

            uint256 totalVestingAllocation = (tokenAmount -
                (ico.ICOunlockRate * tokenAmount) /
                100);

            vestingContract.updateBuyTokens(
                beneficiary,
                _icoType,
                tokenAmount,
                totalVestingAllocation,
                _usdtAmount
            );

        }

        _updatePurchasingState(_usdtAmount, tokenAmount, _icoType);
        _forwardFunds(_usdtAmount);

        if (isIcoMember[beneficiary][_icoType] == false) {
            isIcoMember[beneficiary][_icoType] = true;
            icoMembers[_icoType].push(address(beneficiary));
        }
    }

    /**
     * @dev Owner function. Owner can specify vesting schedule properties through parameters and personalized vesting schedule is created.
     */
    function addingTeamMemberToVesting(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAmount
    ) public onlyOwner isSaleAvailable(_icoType) {
        ICOdata memory ico = ICOdatas[_icoType];
        
        require(
            ico.IsFree==1,
            "ERROR at addingTeamParticipant: Please give correct sale type."
        );
        
        _preValidatePurchase(_beneficiary, _tokenAmount, _icoType);
        
        require(
            !isIcoMember[_beneficiary][_icoType],
            "ERROR at addingTeamParticipant: Beneficiary has already own vesting schedule."
        );

        vestingContract.createVestingSchedule(
            _beneficiary,
            ico.ICOnumberOfCliff,
            ico.ICOnumberOfVesting,
            ico.ICOunlockRate,
            _tokenAmount,
            _icoType,
            0,
            ico.ICOstartDate
        );
        _updatePurchasingState(0, _tokenAmount, _icoType);
        isIcoMember[_beneficiary][_icoType] = true;
        icoMembers[_icoType].push(address(_beneficiary));

    }
    
    /**
     * @dev Client function. Buyer can claim vested tokens according to own vesting schedule.
     */
    function claimAsToken(uint256 _icoType)
        public
        isClaimAvailable(_icoType)
    {
        address beneficiary = msg.sender;

        require(
            isIcoMember[beneficiary][_icoType],
            "ERROR at claimAsToken: You are not the member of this sale."
        );
        require(
            !vestingContract
                .getBeneficiaryVesting(beneficiary, _icoType)
                .revoked,
            "ERROR at claimAsToken: Vesting Schedule is revoked."
        );
        uint256 releasableAmount = vestingContract.getReleasableAmount(
            beneficiary,
            _icoType
        );
        require(
            releasableAmount > 0,
            "ERROR at claimAsToken: Releasable amount is 0."
        );

        _processPurchaseToken(beneficiary, _icoType, releasableAmount);
        ICOdatas[_icoType].ICOtokenSold += releasableAmount;
    }

    
    function revoke(address _beneficiary, uint256 _icoType) external onlyOwner {
        IVesting.VestingScheduleStruct memory vestingSchedule = vestingContract.getBeneficiaryVesting(_beneficiary,_icoType);
        ICOdata storage icoData = ICOdatas[_icoType];
        
        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at revoke: Vesting does not exist."
        );

        require(
            !vestingSchedule.revoked,
            "ERROR at revoke: Vesting Schedule has already revoked."
        );

        uint256 notVestedTokenAllocation = 0;

        //ico is not started yet
        if(block.timestamp < vestingSchedule.icoStartDate){
            icoData.ICOtokenAllocated -= vestingSchedule.cliffAndVestingAllocation;
        }
        //ico is started, not vested amount calc must be done 
        else{
            uint256 releasableAmount = vestingContract.getReleasableAmount(_beneficiary, _icoType);

            //if any vested tokens exist, transfers
            if(releasableAmount > 0){
                _processPurchaseToken(_beneficiary, _icoType, releasableAmount);
                icoData.ICOtokenSold += releasableAmount;
            }

            //not vested tokens calculated to reallocate icodata allocation
            if(vestingSchedule.cliffAndVestingAllocation > vestingSchedule.claimedTokenAmount+releasableAmount){
                notVestedTokenAllocation += (vestingSchedule.cliffAndVestingAllocation - vestingSchedule.claimedTokenAmount - releasableAmount);
            }

            icoData.ICOtokenAllocated -= notVestedTokenAllocation;
            
            /*
            //to check any deviation 
            if(icoData.ICOtokenAllocated > notVestedTokenAllocation){
                icoData.ICOtokenAllocated -= notVestedTokenAllocation;
            }else{
                icoData.ICOtokenAllocated=0;
            }*/
        }
        //vesting schedule structında değişiklikler yapılmak üzere çağrılır.
        vestingContract.vestingRevocation(_beneficiary,_icoType,notVestedTokenAllocation);
    }

    /**
     * @dev Changes sale round state.
     */
    function changeIcoState(uint256 _icoType, IcoState _icoState)
        external
        onlyOwner
    {
        ICOdata storage ico = ICOdatas[_icoType];

        require(ico.ICOstartDate != 0, "Ico does not exist !");

        ico.ICOstate = _icoState;

        if (_icoState == IcoState.done) {
            uint256 saleLeftover= ico.ICOsupply -
                ico.ICOtokenAllocated;

            ico.ICOsupply -= saleLeftover;
            totalLeftover +=saleLeftover;
        }
    }

    /**
     * @dev Increments the supply of a specified type of ICO round.
     */
    function increaseIcoSupplyWithLeftover(uint256 _icoType, uint256 amount)
        external
        onlyOwner
    {
        require(
            ICOdatas[_icoType].ICOstartDate != 0,
            "ERROR at increaseIcoSupplyWithLeftover: Ico does not exist."
        );
        require(
            ICOdatas[_icoType].ICOstate != IcoState.done,
            "ERROR at increaseIcoSupplyWithLeftover: ICO is already done."
        );
        require(
            totalLeftover >= amount,
            "ERROR at increaseIcoSupplyWithLeftover: Not enough leftover."
        );
        ICOdatas[_icoType].ICOsupply += amount;
        totalLeftover -= amount;
    }

    /*
     * @dev Owner can add multiple addresses to whitelist.
     */
    function addToWhitelist(address[] calldata _beneficiaries, uint256 _icoType)
        external 
        onlyOwner
    {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            require(!isWhitelisted(_beneficiaries[i], _icoType), "Already whitelisted");
            whitelist[_icoType][_beneficiaries[i]] = true;
        }
    }

    /**
     * @dev Owner function. Set usdt wallet address.
     * @param _usdtWallet New USDT wallet address.
     */
    function setUSDTWallet(address payable _usdtWallet)
        public
        onlyOwner
    {
        require(
            _usdtWallet != address(0),
            "ERROR at Crowdsale setUSDTWallet: USDT wallet address shouldn't be zero."
        );
        usdtWallet = _usdtWallet;
    }

    /**
     * @dev Owner function. Change IWPA token contract address.
     * @param _token New IWPA token contract address.
     */
    function setTokenContract(address _token) external onlyOwner {
        require(
            _token != address(0),
            "ERROR at Crowdsale setTokenContract: IWPA Token contract address shouldn't be zero."
        );
        token = ERC20(_token);
    }

    /**
     * @dev Owner function. Change vesting contract address.
     * @param _vesting New vesting contract address.
     */
    function setVestingContract(address _vesting)
        external
        onlyOwner
    {
        require(
            _vesting != address(0),
            "ERROR at Crowdsale setVestingContract: Vesting contract address shouldn't be zero address."
        );
        vestingContract = IVesting(_vesting);
    }

    function setUsdtContract(address _usdt)
        external
        onlyOwner
    {
        require(
            _usdt != address(0),
            "ERROR at Crowdsale setUsdtContract: Usdt contract address shouldn't be zero address."
        );
        usdt = ERC20(_usdt);
    }

/*
* @INTERNALS
*/
//////////////////////////////////////////////////////////////////////////////////////////

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
     * @dev Transferring vested tokens to the beneficiary.
     */
    function _processPurchaseToken(
        address _beneficiary,
        uint256 _icoType,
        uint256 _releasableAmount
    ) internal {
        token.transferFrom(owner(), _beneficiary, _releasableAmount*(10**token.decimals()));
        emit processPurchaseTokenEvent(_beneficiary, _icoType, _releasableAmount);
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

        emit updatePurchasingStateEvent(_icoType, ico.ICOname, ico.ICOsupply, ico.ICOtokenAllocated, _tokenAmount, ico.ICOusdtRaised, _usdtAmount);
    }

    /**
     * @dev Returns token amount of the USDT investing.
     * @param _usdtAmount Value in USDT to be converted into tokens.
     * @param _absoluteUsdtPrice Absolute usdt value of token (Actual token usdt price * 10**6)
     * @return Number of tokens that can be purchased with the specified _usdtAmount.
     */
    function _getTokenAmount(uint256 _usdtAmount, uint256 _absoluteUsdtPrice)
        internal
        pure
        returns (uint256)
    {
        _usdtAmount = _usdtAmount * (10**6);
        _usdtAmount = _usdtAmount / _absoluteUsdtPrice;
        return _usdtAmount;
    }

    /**
     * @dev After buy tokens, beneficiary USDT amount transferring to the usdtwallet.
     */
    function _forwardFunds(uint usdtAmount) internal {
        usdt.transferFrom(msg.sender, usdtWallet, usdtAmount*(10**6));
    }

//////////////////////////////////////////////////////////////////////////////////////////

/*
 * @VIEWS
*/
//////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Returns the leftover value.
     */
    function getLeftover()
        external
        view
        returns (uint256)
    {
        return totalLeftover;
    }

    function isWhitelisted(address _beneficiary, uint256 _icoType)
        public
        view
        returns (bool)
    {
        return whitelist[_icoType][_beneficiary] == true;
    }

    /**
     * @dev Returns the members of the specified ICO round.
     */
    function getICOMembers(uint256 _icoType)
        external
        view
        returns (address[] memory)
    {
        require(icoMembers[_icoType].length > 0, "There is no member in this sale.");
        return icoMembers[_icoType];
    }

    /**
     * @dev Returns details of each vesting stages.
     */
    function getVestingList(address _beneficiary, uint256 _icoType)
        external
        view
        returns (VestingScheduleData[] memory)
    {
        require(isIcoMember[_beneficiary][_icoType] == true,"ERROR at getVestingList: You are not the member of this sale.");

        ICOdata memory icoData = ICOdatas[_icoType];

        require(icoData.ICOstartDate != 0, "ICO does not exist");
        
        uint256 size = icoData.ICOnumberOfVesting + 1;

        VestingScheduleData[] memory scheduleArr = new VestingScheduleData[](
            size
        );

        IVesting.VestingScheduleStruct memory vesting = vestingContract.getBeneficiaryVesting(
            _beneficiary,
            _icoType
        );

        uint256 cliffUnlockDateTimestamp = icoData.ICOstartDate;

        uint256 cliffTokenAllocation = (vesting.cliffAndVestingAllocation *
            icoData.ICOunlockRate) / 100;
        
        uint256 cliffUsdtAllocation = (cliffTokenAllocation *
            icoData.TokenAbsoluteUsdtPrice) / 10**6;
        
        scheduleArr[0] = VestingScheduleData({
            id: 0,
            unlockDateTimestamp: cliffUnlockDateTimestamp,
            tokenAmount: cliffTokenAllocation,
            usdtAmount: cliffUsdtAllocation,
            vestingRate: icoData.ICOunlockRate * 1000,
            collected: vesting.tgeVested
        });

        uint256 vestingRateAfterCliff = (1000 * (100 - icoData.ICOunlockRate)) /
            icoData.ICOnumberOfVesting;

        uint256 usdtAmountAfterCliff = (vesting.investedUSDT -
            cliffUsdtAllocation) / icoData.ICOnumberOfVesting;
        uint256 tokenAmountAfterCliff = vesting.vestingAllocation /
            icoData.ICOnumberOfVesting;
        cliffUnlockDateTimestamp += (30 days * icoData.ICOnumberOfCliff);
        
        for (uint256 i = 0; i < icoData.ICOnumberOfVesting; ++i) {
            bool isCollected=false;
            if(i<vesting.releasedPeriod){
                isCollected=true;
            }
            cliffUnlockDateTimestamp += 30 days;
            scheduleArr[i + 1] = VestingScheduleData({
                id: i + 1,
                unlockDateTimestamp: cliffUnlockDateTimestamp,
                tokenAmount: tokenAmountAfterCliff,
                usdtAmount: usdtAmountAfterCliff,
                vestingRate: vestingRateAfterCliff,
                collected: isCollected
            });
        }
        return scheduleArr;
    }

    /**
     * @dev Returns details of ICOs.
     */
    function getICODatas() external view returns (ICOdata[] memory) {
        return ICOdatas;
    }

//////////////////////////////////////////////////////////////////////////////////////////
}
