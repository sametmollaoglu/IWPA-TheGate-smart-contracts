// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/Vesting.sol";

//seed sale flag => 0
//private sale flag => 1

interface IVesting {
    struct VestingScheduleData {
        uint256 id;
        uint256 unlockDateTimestamp;
        uint256 tokenAmount;
        uint256 usdtAmount;
        uint256 vestingRate;
    }

    function getVestingListDetails(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAbsoluteUsdtPrice,
        uint256 _ICOnumberOfVesting
    ) external view returns (VestingScheduleData[] memory vestingSchedule);
}

contract Crowdsale is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // Address where funds are collected as USDT
    address payable public usdtWallet;
    // Address where TENET tokens are stored
    address payable public tenetWallet;

    ERC20 public token;
    IERC20 public usdt = IERC20(0xA2c7341dAdB120aa638795Dc73f7c74Ebd35D868);
    IERC20 public tenet;

    Vesting vestingContract;
    ICOdata[] private ICOdatas;

    uint256 private totalAllocation;
    uint256 private totalLeftover;

    mapping(uint256 => mapping(address => bool)) private whitelist;
    mapping(address => mapping(uint256 => bool)) private isIcoMember;
    mapping(uint256 => address[]) private icoMembers;

    event tokenClaimed(
        address _beneficiary,
        uint256 _icoType,
        uint256 releasedAmount
    );
    event UsdtClaimed(
        address _beneficiary,
        uint256 _icoType,
        uint256 releasedUsdtAmount
    );
    event priceChanged(string ICOname, uint256 oldPrice, uint256 newPrice);

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
        //Start date of the ICO sale
        uint256 ICOstartDate;
        //Absolute token price (tokenprice(USDT) * (10**6))
        uint256 TokenAbsoluteUsdtPrice;
        //If the team vesting data, should be free participation vesting for only to specific addresses
        bool IsFree;
    }

    //Checks whether the specific ICO sale is active or not
    modifier isIcoAvailable(uint256 _icoType) {
        require(ICOdatas[_icoType].ICOstartDate != 0, "Ico does not exist !");
        require(
            ICOdatas[_icoType].ICOstate == IcoState.onlyWhitelist ||
                ICOdatas[_icoType].ICOstate == IcoState.active,
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
        vestingContract = Vesting(_vestingContract);
    }

    /*
     * @param _rate How many token units a buyer gets per USDT at ICO sale.
     * @param _supply Number of token will be in ICO sale.
     * @param _cliffMonths Number of cliff months of ICO sale.
     * @param _vestingMonths Number of vesting months of ICO sale.
     * @param _unlockRate Unlock rate of the ICO sale.
     * @param _startDate Start date of the ICO sale.
     * @param _tokenAbsoluteUsdtPrice Absolute token price.
     */
    function createICO(
        string memory _name,
        uint256 _supply,
        uint256 _cliffMonths,
        uint256 _vestingMonths,
        uint8 _unlockRate,
        uint256 _startDate,
        uint256 _tokenAbsoluteUsdtPrice, //0 if free
        bool _isFree
    ) external onlyOwner {
        if (!_isFree) {
            require(
                _tokenAbsoluteUsdtPrice > 0,
                "ERROR at createICO: Token price should be bigger than zero."
            );
        }
        require(
            _supply > 0,
            "ERROR at createICO: Supply should be bigger than zero."
        );
        require(
            _startDate >= block.timestamp,
            "ERROR at createICO: Start date must be greater than now."
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
                TokenAbsoluteUsdtPrice: _tokenAbsoluteUsdtPrice,
                IsFree: _isFree
            })
        );
    }

    /**
     * @dev Client function. Buyer can buy tokens and became participant of own vesting schedule.
     * @param _icoType To specify type of the ICO sale.
     * @param _usdtAmount Usdt amount used for purchasing tokens.
     */
    function buyTokens(uint256 _icoType, uint256 _usdtAmount)
        public
        nonReentrant
        isIcoAvailable(_icoType)
    {
        ICOdata memory ico = ICOdatas[_icoType];
        address beneficiary = msg.sender;

        require(
            !ICOdatas[_icoType].IsFree,
            "This token distribution is exclusive to the team only."
        );
        require(
            ico.ICOstartDate != 0,
            "ERROR at buyTokens: Ico does not exist."
        );
        require(
            ico.ICOstartDate >= block.timestamp,
            "ERROR at buyTokens: ICO date expired."
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
                true,
                tokenAmount,
                _icoType,
                _usdtAmount,
                ico.ICOstartDate,
                ico.TokenAbsoluteUsdtPrice
            );
        } else {
            uint256 totalVestingAllocation = (tokenAmount -
                (ico.ICOunlockRate * tokenAmount) /
                100);

            vestingContract.increaseCliffAndVestingAllocation(
                beneficiary,
                _icoType,
                tokenAmount
            );
            vestingContract.increaseVestingAllocation(
                beneficiary,
                _icoType,
                totalVestingAllocation
            );
            vestingContract.increaseInvestedUsdt(
                beneficiary,
                _icoType,
                _usdtAmount
            );
        }

        _updatePurchasingState(_usdtAmount, tokenAmount, _icoType);
        _forwardFunds(_usdtAmount);
        if (isIcoMember[beneficiary][_icoType] == false) {
            isIcoMember[beneficiary][_icoType] = true;
            icoMembers[_icoType].push(beneficiary);
        }
    }

    function addingTeamMemberToVesting(uint256 _icoType, uint256 _tokenAmount)
        public
        onlyOwner
        nonReentrant
        isIcoAvailable(_icoType)
    {
        ICOdata memory ico = ICOdatas[_icoType];
        address beneficiary = msg.sender;

        require(beneficiary != address(0));
        require(
            ico.ICOstartDate != 0,
            "ERROR at addingTeamParticipant: Ico does not exist."
        );
        require(ICOdatas[_icoType].IsFree, "");
        require(
            ico.ICOstartDate >= block.timestamp,
            "ERROR at addingTeamParticipant: ICO date expired."
        );
        //_preValidatePurchase(beneficiary, _tokenAmount, _icoType);
        require(
            ICOdatas[_icoType].ICOtokenAllocated + _tokenAmount <=
                ICOdatas[_icoType].ICOsupply,
            "Not enough token in the ICO supply"
        );

        vestingContract.createVestingSchedule(
            beneficiary,
            ico.ICOnumberOfCliff,
            ico.ICOnumberOfVesting,
            ico.ICOunlockRate,
            true,
            _tokenAmount,
            _icoType,
            0,
            ico.ICOstartDate,
            0
        );

        _updatePurchasingState(0, _tokenAmount, _icoType);
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
        uint256 releasableAmount = vestingContract.getReleasableAmount(
            beneficiary,
            _icoType
        );

        require(
            releasableAmount > 0,
            "ERROR at claimAsToken: Releasable amount is 0."
        );
        require(
            !vestingContract
                .getBeneficiaryVesting(beneficiary, _icoType)
                .revoked,
            "ERROR at claimAsToken: Vesting Schedule is revoked."
        );

        _processPurchaseToken(beneficiary, _icoType, releasableAmount);
        ICOdatas[_icoType].ICOtokenSold += releasableAmount;
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
        uint256 releasableUsdtAmount = vestingContract.getReleasableUsdtAmount(
            beneficiary,
            _icoType
        );

        require(
            releasableUsdtAmount > 0,
            "ERROR at claimAsUsdt: Releasable USDT amount is 0."
        );
        require(
            !vestingContract
                .getBeneficiaryVesting(beneficiary, _icoType)
                .revoked,
            "ERROR at release: Vesting Schedule is revoked."
        );

        _processPurchaseUSDT(beneficiary, _icoType, releasableUsdtAmount);
        ICOdatas[_icoType].ICOusdtRaised -= releasableUsdtAmount;
        ICOdatas[_icoType].ICOtokenAllocated -= (releasableUsdtAmount /
            ICOdatas[_icoType].TokenAbsoluteUsdtPrice);
    }

    function claimTeamVesting(uint256 _icoType)
        public
        nonReentrant
        isIcoAvailable(_icoType)
    {
        address beneficiary = msg.sender;
        uint256 releasableAmount = vestingContract.getReleasableAmount(
            beneficiary,
            _icoType
        );

        require(
            releasableAmount > 0,
            "ERROR at claimTeamVesting: Releasable amount is 0."
        );
        require(
            !vestingContract
                .getBeneficiaryVesting(beneficiary, _icoType)
                .revoked,
            "ERROR at claimTeamVesting: Vesting Schedule is revoked."
        );

        _processPurchaseToken(beneficiary, _icoType, releasableAmount);
        ICOdatas[_icoType].ICOtokenSold += releasableAmount;
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
     * @dev Transferring vested tokens to the beneficiary.
     */
    function _processPurchaseToken(
        address _beneficiary,
        uint256 _icoType,
        uint256 _releasableAmount
    ) internal {
        token.transferFrom(owner(), _beneficiary, _releasableAmount);
        emit tokenClaimed(_beneficiary, _icoType, _releasableAmount);
    }

    /**
     * @dev Transferring USDT value for vested tokens instead of claiming tokens.
     */
    function _processPurchaseUSDT(
        address _beneficiary,
        uint256 _icoType,
        uint256 _releasableUsdt
    ) internal {
        usdt.transferFrom(tenetWallet, _beneficiary, _releasableUsdt); //usdt contract will be tenet contract
        emit UsdtClaimed(_beneficiary, _icoType, _releasableUsdt);
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
     * @notice Team vestings should be onlywhitelist state
     */
    function changeIcoState(uint256 _icoType, IcoState _icoState)
        external
        onlyOwner
    {
        ICOdatas[_icoType].ICOstate = _icoState;
        if (_icoState == IcoState.done) {
            totalLeftover += (ICOdatas[_icoType].ICOsupply -
                ICOdatas[_icoType].ICOtokenAllocated);
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

    /**
     * @dev Returns the leftover value.
     */
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
     * @dev Owner can add an address to whitelist.
     */
    function addToWhitelist(address[] memory _beneficiaries, uint256 _icoType)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            addAddressToWhitelist(_beneficiaries[i], _icoType);
        }
    }

    function addAddressToWhitelist(address _beneficiary, uint256 _icoType)
        public
        onlyOwner
    {
        require(!isWhitelisted(_beneficiary, _icoType), "Already whitelisted");
        whitelist[_icoType][_beneficiary] = true;
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

    /**
     * @dev Returns details of each vesting stages.
     */
    function getVestingList(uint256 _icoType)
        external
        view
        returns (IVesting.VestingScheduleData[] memory vestingSchedule)
    {
        address beneficiary = msg.sender;
        ICOdata memory data = ICOdatas[_icoType];
        require(data.TokenAbsoluteUsdtPrice != 0, "ICO does not exist");

        return
            IVesting(address(vestingContract)).getVestingListDetails(
                beneficiary,
                _icoType,
                data.TokenAbsoluteUsdtPrice,
                data.ICOnumberOfVesting
            );
    }

    /**
     * @dev Returns details of ICOs.
     */
    function getICODatas() external view onlyOwner returns (ICOdata[] memory) {
        return ICOdatas;
    }

    /**
     * @dev Changes absolute token USDT price.
     */
    function changeAbsoluteTokenUsdtPrice(
        uint256 _newTokenPrice,
        uint256 _icoType
    ) external onlyOwner {
        ICOdata storage data = ICOdatas[_icoType];
        require(
            block.timestamp < data.ICOstartDate,
            "ICO has already started."
        );
        uint256 oldPrice = data.TokenAbsoluteUsdtPrice;
        data.TokenAbsoluteUsdtPrice = _newTokenPrice;
        emit priceChanged(data.ICOname, oldPrice, _newTokenPrice);
    }

    /**
     * @dev Owner function. Change vesting contract address.
     * @param _newVestingContractAddress New vesting contract address.
     */
    function setVestingContractAddress(address _newVestingContractAddress)
        external
        onlyOwner
    {
        require(
            _newVestingContractAddress != address(0),
            "ERROR at Crowdsale setVestingContractAddress: Vesting contract address shouldn't be zero address."
        );
        vestingContract = Vesting(_newVestingContractAddress);
    }

    function setUsdtContractAddress(address _newUsdtContractAddress)
        external
        onlyOwner
    {
        require(
            _newUsdtContractAddress != address(0),
            "ERROR at Crowdsale setUsdtContractAddress: Usdt contract address shouldn't be zero address."
        );
        usdt = ERC20(_newUsdtContractAddress);
    }
}
