// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Vesting is Ownable {

    //Address of the ERC20 token
    ERC20 public token;
    address crowdsaleContractAddress;

    mapping(address => mapping(uint256 => VestingScheduleStruct))
        internal vestingSchedules;

    constructor(address tokenAddress) {
        require(tokenAddress != address(0x0));
        token = ERC20(tokenAddress);
    }

    receive() external payable {}

    fallback() external payable {}

/*
 * @MODIFIERS
*/
//////////////////////////////////////////////////////////////////////////////////////////

    modifier onlyCrowdsale() {
        require(
            msg.sender == address(crowdsaleContractAddress),
            "Only crowdsale contract can call this function."
        );
        _;
    }

//////////////////////////////////////////////////////////////////////////////////////////

/*
 * @EVENTS
*/
//////////////////////////////////////////////////////////////////////////////////////////

    event VestingScheduleAdded(
        address beneficiary,
        uint256 numberOfCliffMonths,
        uint256 numberOfVestingMonths,
        uint256 unlockRate,
        uint256 allocation,
        uint256 IcoType
    );

    event VestingScheduleRevoked(
        address beneficiary,
        uint256 IcoType,
        bool tgeVested,
        uint256 releasedPeriod,
        uint256 revokedTokenAllocation
    );

//////////////////////////////////////////////////////////////////////////////////////////

    struct VestingScheduleStruct {
        address beneficiaryAddress; //Address of the vesting schedule beneficiary.
        uint256 icoStartDate; //Ico start date
        uint256 numberOfCliff; //Number of cliff months
        uint256 numberOfVesting; //Number of vesting months
        uint256 unlockRate; //Initial vesting rate of beneficiary
        bool revoked; // Whether or not the vesting has been revoked
        uint256 cliffAndVestingAllocation; // Total amount of tokens to be released at the end of the vesting cliff + vesting
        uint256 vestingAllocation; // Total amount of tokens to be released at the end of the vesting only vesting
        uint256 claimedTokenAmount; //total amount of tokens claimed, added to check distributed token amount correctly
        bool tgeVested; //Whether or not the tge has been vested
        uint256 releasedPeriod; //Already released months
        uint256 icoType; //Type of ICO  0=>seed, 1=>private
        uint256 investedUSDT; //Beneficiary addresses and their investments
    }

    /**
     * @dev Owner function. Change crowdsale contract address.
     */
    function setCrowdsaleContractAddress(address _newCrowdsaleContractAddress)
        external
        onlyOwner
    {
        require(
            _newCrowdsaleContractAddress != address(0),
            "ERROR at Vesting setCrowdsaleContractAddress: Crowdsale contract address shouldn't be zero address."
        );
        crowdsaleContractAddress = address(_newCrowdsaleContractAddress);
    }

/*
 * @ONLYCROWDSALE
*/
//////////////////////////////////////////////////////////////////////////////////////////

    /**
    * @dev Creates a new vesting schedule.
    */
    function createVestingSchedule(
        address _beneficiary,
        uint256 _numberOfCliffMonths,
        uint256 _numberOfVestingMonths,
        uint256 _unlockRate,
        uint256 _allocation,
        uint256 _IcoType,
        uint256 _investedUsdt,
        uint256 _icoStartDate
    ) external onlyCrowdsale {

        uint256 totalVestingAllocation = (_allocation -
            (_unlockRate * _allocation) /
            100);

        vestingSchedules[_beneficiary][_IcoType] = VestingScheduleStruct(
            _beneficiary,
            _icoStartDate,
            _numberOfCliffMonths,
            _numberOfVestingMonths,
            _unlockRate,
            false,
            _allocation,
            totalVestingAllocation,
            0,
            false,
            0,
            _IcoType,
            _investedUsdt
        );

        emit VestingScheduleAdded(
            _beneficiary,
            _numberOfCliffMonths,
            _numberOfVestingMonths,
            _unlockRate,
            _allocation,
            _IcoType
        );
    }

    /**
     * @dev Revokes given vesting schedule.
     * @dev revoke edilen vesting schedule içerisindeki allocation değerleri getvestinglistte kullanıldığından değiştirilmedi
     */
    function vestingRevocation(address _beneficiary, uint256 _icoType, uint256 _notVestedTokenAllocation) external onlyCrowdsale {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.beneficiaryAddress != address(0x0),
            "ERROR: Vesting does not exist."
        );

        vestingSchedule.revoked = true;

        /*
        if(_notVestedTokenAllocation<vestingSchedule.cliffAndVestingAllocation || _notVestedTokenAllocation<vestingSchedule.vestingAllocation){
            vestingSchedule.cliffAndVestingAllocation-=_notVestedTokenAllocation;
            vestingSchedule.vestingAllocation-=_notVestedTokenAllocation;
        }else{
            vestingSchedule.cliffAndVestingAllocation=0;
            vestingSchedule.vestingAllocation=0;
        }
        */

        emit VestingScheduleRevoked(
            _beneficiary,
            _icoType,
            vestingSchedule.tgeVested,
            vestingSchedule.releasedPeriod,
            _notVestedTokenAllocation
        );
    }

    /**
     * @dev Calculates the vested amount of given vesting schedule.
     */
    function getReleasableAmount(address _beneficiary, uint256 _icoType)
        external
        onlyCrowdsale
        returns (uint256)
    {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at getReleasableAmount: Vesting does not exist."
        );
        
        /*
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at getReleasableAmount: You claimed all of your vesting."
        );
        */

        uint256 currentTime = block.timestamp;

        require(
            currentTime > vestingSchedule.icoStartDate,
            "ERROR at getReleasableAmount: ICO is not started yet"
        );
        
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );

        if (
            elapsedMonthNumber >
            vestingSchedule.numberOfVesting + vestingSchedule.numberOfCliff
        ) {
            elapsedMonthNumber =
                vestingSchedule.numberOfVesting +
                vestingSchedule.numberOfCliff;
        }

        uint256 releasableAmount = 0;
        
        if (!vestingSchedule.tgeVested) {
            uint256 unlockAmount = (vestingSchedule.cliffAndVestingAllocation *
                vestingSchedule.unlockRate) / 100;
            releasableAmount += unlockAmount;
            vestingSchedule.tgeVested = true;
        }

        if (elapsedMonthNumber > vestingSchedule.numberOfCliff + vestingSchedule.releasedPeriod) {
            uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

            uint256 vestedAmount = (vestingSchedule.vestingAllocation /
                vestingSchedule.numberOfVesting) * vestedMonthNumber;
            releasableAmount += vestedAmount;
            vestingSchedule.releasedPeriod += vestedMonthNumber;
        }

        vestingSchedule.claimedTokenAmount+=releasableAmount;
        
        return releasableAmount;
    }

    /**
     * @dev Only crowdsale contract functions can call this function. Crowdsale buytokens function calls this function.
     */
    function updateBuyTokens(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAmount,
        uint256 _totalVestingAllocation,
        uint256 _usdtAmount
    ) external onlyCrowdsale {
        vestingSchedules[_beneficiary][_icoType]
            .cliffAndVestingAllocation += _tokenAmount;

        vestingSchedules[_beneficiary][_icoType]
            .vestingAllocation += _totalVestingAllocation;
        
        vestingSchedules[_beneficiary][_icoType].investedUSDT += _usdtAmount;
    }

//////////////////////////////////////////////////////////////////////////////////////////

/*
 * @INTERNALS
*/
//////////////////////////////////////////////////////////////////////////////////////////    

    /**
     * @dev Calculates the elapsed month.
     * @param vestingSchedule Beneficiary vesting schedule struct.
     * @param currentTime Given by parameter to avoid transaction call latency.
     */
    function _getElapsedMonth(
        VestingScheduleStruct memory vestingSchedule,
        uint256 currentTime
    ) internal pure returns (uint256) {
        return (currentTime - vestingSchedule.icoStartDate) / 300;
    }

//////////////////////////////////////////////////////////////////////////////////////////

/*
 * @VIEWS
*/
//////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Get token allocation of vesting schedule
     * @dev silinebilir
     */
    function getScheduleTokenAllocation(address _beneficiary, uint256 _icoType)
        external
        view
        returns (uint256)
    {
        return
            vestingSchedules[_beneficiary][_icoType].cliffAndVestingAllocation;
    }

    /**
     * @dev Views releasable token amount of vesting schedule.
     * @dev silinebilir
     */
    function viewReleasableAmount(address _beneficiary, uint256 _icoType)
        public
        view
        returns (uint256)
    {
        VestingScheduleStruct memory vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            _beneficiary != address(0),
            "ERROR at viewReleasableAmount: Beneficiary address is not valid."
        );
        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at viewReleasableAmount: Vesting does not exist."
        );
        
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at viewReleasableAmount: You claimed all of your vesting."
        );

        uint256 currentTime = block.timestamp;

        require(
            currentTime > vestingSchedule.icoStartDate,
            "ERROR at viewReleasableAmount: ICO is not started yet"
        );
        
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );

        if (
            elapsedMonthNumber >
            vestingSchedule.numberOfVesting + vestingSchedule.numberOfCliff
        ) {
            elapsedMonthNumber =
                vestingSchedule.numberOfVesting +
                vestingSchedule.numberOfCliff;
        }

        uint256 releasableAmount = 0;
        
        if (!vestingSchedule.tgeVested) {
            uint256 unlockAmount = (vestingSchedule.cliffAndVestingAllocation *
                vestingSchedule.unlockRate) / 100;
            releasableAmount += unlockAmount;
        }

        if (elapsedMonthNumber > vestingSchedule.numberOfCliff + vestingSchedule.releasedPeriod) {
            uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

            uint256 vestedAmount = (vestingSchedule.vestingAllocation /
                vestingSchedule.numberOfVesting) * vestedMonthNumber;
            releasableAmount += vestedAmount;
        }
        return releasableAmount;
    }

    /**
     * @dev Views releasable usdt amount of vesting schedule.
     * @dev silinebilir
     */
    function viewReleasableUsdtAmount(address _beneficiary, uint256 _icoType)
        external 
        view
        returns (uint256)
    {
        VestingScheduleStruct memory vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            _beneficiary != address(0),
            "ERROR at viewReleasableUsdtAmount: Beneficiary address is not valid."
        );
        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at viewReleasableUsdtAmount: Vesting does not exist !"
        );

        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at viewReleasableUsdtAmount: You claimed all of your vesting."
        );

        uint256 currentTime = block.timestamp;

        require(
            currentTime > vestingSchedule.icoStartDate,
            "ERROR at viewReleasableUsdtAmount: ICO is not started yet"
        );
        
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );

        if (
            elapsedMonthNumber >
            vestingSchedule.numberOfVesting + vestingSchedule.numberOfCliff
        ) {
            elapsedMonthNumber =
                vestingSchedule.numberOfVesting +
                vestingSchedule.numberOfCliff;
        }

        uint256 releasableUsdtAmount = 0;

        if (!vestingSchedule.tgeVested) {
            uint256 unlockUsdtAmount = (vestingSchedule.investedUSDT *
                vestingSchedule.unlockRate) / 100;
            releasableUsdtAmount += unlockUsdtAmount;
        }

        if (elapsedMonthNumber > vestingSchedule.numberOfCliff + vestingSchedule.releasedPeriod) {
            uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

            uint256 totalVestingUsdtAmount = (vestingSchedule.investedUSDT *
                (100 - vestingSchedule.unlockRate)) / 100;
                
            uint256 vestedUsdtAmount = (totalVestingUsdtAmount *
                vestedMonthNumber) / vestingSchedule.numberOfVesting;

            releasableUsdtAmount += vestedUsdtAmount;
        }
        
        return releasableUsdtAmount;
    }

    function getBeneficiaryVesting(address beneficiary, uint256 icoType)
        external 
        view
        returns (VestingScheduleStruct memory)
    {
        return vestingSchedules[beneficiary][icoType];
    }

//////////////////////////////////////////////////////////////////////////////////////////
    
}
