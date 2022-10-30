// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vesting is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    //Address of the ERC20 token
    ERC20 public token;
    address crowdsaleContractAddress;

    mapping(address => mapping(uint256 => VestingScheduleStruct))
        internal vestingSchedules;

    constructor(address tokenAddress) {
        require(tokenAddress != address(0x0));
        token = ERC20(tokenAddress);
    }

    modifier onlyCrowdsale() {
        require(
            msg.sender == address(crowdsaleContractAddress),
            "Only crowdsale contract can call this function."
        );
        _;
    }

    event VestingScheduleAdded(
        address beneficiary,
        uint256 numberOfCliffMonths,
        uint256 numberOfVestingMonths,
        uint256 unlockRate,
        bool isRevocable,
        uint256 allocation,
        uint256 IcoType,
        uint256 _tokenAbsoluteUsdtPrice
    );

    event VestingScheduleRevoked(address account, uint256 releasedAmount);

    struct VestingScheduleStruct {
        address beneficiaryAddress; //Address of the vesting schedule beneficiary.
        uint256 icoStartDate; //Ico start date
        uint256 numberOfCliff; //Number of cliff months
        uint256 numberOfVesting; //Number of vesting months
        uint256 unlockRate; //Initial vesting rate of beneficiary
        bool isRevocable; // Whether or not the vesting is revocable
        bool revoked; // Whether or not the vesting has been revoked
        uint256 cliffAndVestingAllocation; // Total amount of tokens to be released at the end of the vesting cliff + vesting
        uint256 vestingAllocation; // Total amount of tokens to be released at the end of the vesting only vesting
        bool tgeVested; //Whether or not the tge has been vested
        uint256 releasedPeriod; //Already released months
        uint256 icoType; //Type of ICO  0=>seed, 1=>private
        uint256 investedUSDT; //Beneficiary addresses and their investments
        bool isClaimed; //Shows whether assigned tokens is claimed or not
        uint256 tokenAbsoluteUsdtPrice; //Absolute USDT price for a token
    }

    /**
     * @dev Creates a new vesting schedule.
     * @param _beneficiary Address of the beneficiary
     * @param _numberOfCliffMonths Number of cliff months
     * @param _numberOfVestingMonths Number of vesting months
     * @param _unlockRate Initial vesting rate
     * @param _isRevocable Whether can be revoked or not
     * @param _allocation Total allocation amount
     * @param _IcoType Ico type  0=>seed, 1=>private
     * @param _investedUsdt Amount of invested USDT
     * @param _icoStartDate Start date of ICO
     * @param _tokenAbsoluteUsdtPrice Absolute USDT price for a token
     */
    function createVestingSchedule(
        address _beneficiary,
        uint256 _numberOfCliffMonths,
        uint256 _numberOfVestingMonths,
        uint256 _unlockRate,
        bool _isRevocable,
        uint256 _allocation,
        uint256 _IcoType,
        uint256 _investedUsdt,
        uint256 _icoStartDate,
        uint256 _tokenAbsoluteUsdtPrice
    ) external onlyCrowdsale {
        require(
            vestingSchedules[_beneficiary][_IcoType].beneficiaryAddress ==
                address(0x0),
            "ERROR (createVestingSchedule): Schedule already exist."
        );
        require(
            _numberOfVestingMonths > 0,
            "ERROR at createVestingSchedule: Vesting cannot be 0 month"
        );

        uint256 totalVestingAllocation = (_allocation -
            (_unlockRate * _allocation) /
            100);

        vestingSchedules[_beneficiary][_IcoType] = VestingScheduleStruct(
            _beneficiary,
            _icoStartDate,
            _numberOfCliffMonths,
            _numberOfVestingMonths,
            _unlockRate,
            _isRevocable,
            false,
            _allocation,
            totalVestingAllocation,
            false,
            0,
            _IcoType,
            _investedUsdt,
            false,
            _tokenAbsoluteUsdtPrice
        );

        emit VestingScheduleAdded(
            _beneficiary,
            _numberOfCliffMonths,
            _numberOfVestingMonths,
            _unlockRate,
            _isRevocable,
            _allocation,
            _IcoType,
            _tokenAbsoluteUsdtPrice
        );
    }

    /**
     * @notice Revokes given vesting schedule.
     * @param _beneficiary Address of the beneficiary.
     * @param _icoType Ico type
     */
    function revoke(address _beneficiary, uint256 _icoType) external onlyOwner {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];
        require(
            vestingSchedule.beneficiaryAddress != address(0x0),
            "ERROR: Vesting Schedule already exist."
        );
        require(
            vestingSchedule.isRevocable,
            "ERROR at revoke: Target schedule is not revokable."
        );
        require(
            !vestingSchedule.revoked,
            "ERROR at revoked: Vesting Schedule has already revoked."
        );

        uint256 releasableAmount = viewReleasableAmount(_beneficiary, _icoType);
        address payable beneficiaryAccount = payable(
            vestingSchedule.beneficiaryAddress
        );

        token.transferFrom(owner(), beneficiaryAccount, releasableAmount);
        vestingSchedule.revoked = true;
        emit VestingScheduleRevoked(_beneficiary, releasableAmount);
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
            _beneficiary != address(0),
            "ERROR at getReleasableAmount: Beneficiary address is not valid."
        );
        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at getReleasableAmount: Vesting does not exist."
        );
        require(
            block.timestamp > vestingSchedule.icoStartDate,
            "ERROR at getReleasableAmount: ICO is not started yet"
        );
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at getReleasableAmount: You claimed all of your vesting."
        );

        uint256 releasableAmount = 0;
        uint256 currentTime = block.timestamp;
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

        uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

        if (!vestingSchedule.tgeVested) {
            uint256 unlockAmount = (vestingSchedule.cliffAndVestingAllocation *
                vestingSchedule.unlockRate) / 100;
            releasableAmount += unlockAmount;
            vestingSchedule.tgeVested = true;
        }
        if (vestedMonthNumber > 0) {
            uint256 vestedAmount = (vestingSchedule.vestingAllocation /
                vestingSchedule.numberOfVesting) * vestedMonthNumber;
            releasableAmount += vestedAmount;
            vestingSchedule.releasedPeriod += vestedMonthNumber;
        }
        return releasableAmount;
    }

    /**
     * @dev Calculates the vested amount of given vesting schedule.
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
            block.timestamp > vestingSchedule.icoStartDate,
            "ERROR at viewReleasableAmount: ICO is not started yet"
        );
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at viewReleasableAmount: You claimed all of your vesting."
        );

        uint256 releasableAmount = 0;
        uint256 currentTime = block.timestamp;
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

        uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

        if (!vestingSchedule.tgeVested) {
            uint256 unlockAmount = (vestingSchedule.cliffAndVestingAllocation *
                vestingSchedule.unlockRate) / 100;
            releasableAmount += unlockAmount;
        }
        if (vestedMonthNumber > 0) {
            uint256 vestedAmount = (vestingSchedule.vestingAllocation /
                vestingSchedule.numberOfVesting) * vestedMonthNumber;
            releasableAmount += vestedAmount;
        }
        return releasableAmount;
    }

    /**
     * @dev Get invested amount of USDT of vesting schedule
     */
    function getReleasableUsdtAmount(address _beneficiary, uint256 _icoType)
        external
        onlyCrowdsale
        returns (uint256)
    {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            _beneficiary != address(0),
            "ERROR at getReleasableUsdtAmount: Beneficiary address is not valid."
        );
        require(
            vestingSchedule.icoStartDate != 0,
            "ERROR at getReleasableUsdtAmount: Vesting does not exist."
        );
        require(
            block.timestamp > vestingSchedule.icoStartDate,
            "ERROR at getReleasableUsdtAmount: ICO is not started yet."
        );
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at getReleasableUsdtAmount: You claimed all of your vesting."
        );

        uint256 releasableUsdtAmount = 0;
        uint256 currentTime = block.timestamp;
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

        uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

        if (!vestingSchedule.tgeVested) {
            uint256 unlockUsdtAmount = (vestingSchedule.investedUSDT *
                vestingSchedule.unlockRate) / 100;
            releasableUsdtAmount += unlockUsdtAmount;
            vestingSchedule.tgeVested = true;
        }
        if (vestedMonthNumber > 0) {
            uint256 totalVestingUsdtAmount = (vestingSchedule.investedUSDT *
                (100 - vestingSchedule.unlockRate)) / 100;
            uint256 vestedUsdtAmount = (totalVestingUsdtAmount *
                vestedMonthNumber) / vestingSchedule.numberOfVesting;
            releasableUsdtAmount += vestedUsdtAmount;
            vestingSchedule.releasedPeriod += vestedMonthNumber;
        }
        return releasableUsdtAmount;
    }

    /**
     * @dev Get invested amount of USDT of vesting schedule
     */
    function viewReleasableUsdtAmount(address _beneficiary, uint256 _icoType)
        public
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
            block.timestamp > vestingSchedule.icoStartDate,
            "ERROR at viewReleasableUsdtAmount: ICO is not started yet"
        );
        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "ERROR at viewReleasableUsdtAmount: You claimed all of your vesting."
        );

        uint256 releasableUsdtAmount = 0;
        uint256 currentTime = block.timestamp;
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

        uint256 vestedMonthNumber = elapsedMonthNumber -
            vestingSchedule.numberOfCliff -
            vestingSchedule.releasedPeriod;

        if (!vestingSchedule.tgeVested) {
            uint256 unlockUsdtAmount = (vestingSchedule.investedUSDT *
                vestingSchedule.unlockRate) / 100;
            releasableUsdtAmount += unlockUsdtAmount;
        }
        if (vestedMonthNumber > 0) {
            uint256 totalVestingUsdtAmount = (vestingSchedule.investedUSDT *
                (100 - vestingSchedule.unlockRate)) / 100;
            uint256 vestedUsdtAmount = (totalVestingUsdtAmount *
                vestedMonthNumber) / vestingSchedule.numberOfVesting;
            releasableUsdtAmount += vestedUsdtAmount;
        }
        return releasableUsdtAmount;
    }

    /**
     * @dev Calculates the elapsed month of the given schedule so far.
     * @param vestingSchedule Beneficiary vesting schedule struct.
     * @param currentTime Given by parameter to avoid transaction call latency.
     */
    function _getElapsedMonth(
        VestingScheduleStruct memory vestingSchedule,
        uint256 currentTime
    ) internal pure returns (uint256) {
        return (currentTime - vestingSchedule.icoStartDate) / (30 days);
    }

    /**
     * @dev Get token allocation of vesting schedule by using beneficiary address and ico type
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
     * @dev Update specified vesting schedule start date.
     */
    function updateVestingStartDate(
        uint256 _startDate,
        uint256 _icoType,
        address _beneficiary
    ) external onlyOwner {
        require(
            block.timestamp <
                vestingSchedules[_beneficiary][_icoType].icoStartDate,
            "ERROR at updateVestingStartDate: ICO is already started, start date has not changed."
        );
        vestingSchedules[_beneficiary][_icoType].icoStartDate = _startDate;
    }

    /*
     * @notice Deletes vesting schedule by using beneficiary address and ico type
     * @param _beneficiary Beneficiary vesting schedule struct.
     * @param _icoType Beneficiary vesting schedule struct.
     
    function deleteSchedule(address _beneficiary, uint256 _icoType) external {
        totalAllocation -= vestingSchedules[_beneficiary][_icoType].allocation;
        delete vestingSchedules[_beneficiary][_icoType];
    }
    */

    /**
     * @dev Only crowdsale contract functions can call this function. Using for returning specific vesting schedule.
     */
    function getBeneficiaryVesting(address beneficiary, uint256 icoType)
        public
        view
        onlyCrowdsale
        returns (VestingScheduleStruct memory)
    {
        return vestingSchedules[beneficiary][icoType];
    }

    /**
     * @dev Only crowdsale contract functions can call this function. Crowdsale buytokens function calls this function.
     */
    function increaseCliffAndVestingAllocation(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAmount
    ) external onlyCrowdsale {
        vestingSchedules[_beneficiary][_icoType]
            .cliffAndVestingAllocation += _tokenAmount;
    }

    /**
     * @dev Only crowdsale contract functions can call this function. Crowdsale buytokens function calls this function.
     */
    function increaseVestingAllocation(
        address _beneficiary,
        uint256 _icoType,
        uint256 _totalVestingAllocation
    ) external onlyCrowdsale {
        vestingSchedules[_beneficiary][_icoType]
            .vestingAllocation += _totalVestingAllocation;
    }

    /**
     * @dev Only crowdsale contract functions can call this function. Crowdsale buytokens function calls this function.
     */
    function increaseInvestedUsdt(
        address _beneficiary,
        uint256 _icoType,
        uint256 _usdtAmount
    ) external onlyCrowdsale {
        vestingSchedules[_beneficiary][_icoType].investedUSDT += _usdtAmount;
    }

    /**
     * @dev Owner function. Change crowdsale contract address.
     * @param _newCrowdsaleContractAddress New crowdsale contract address.
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

    struct VestingScheduleData {
        uint256 id;
        uint256 unlockDateTimestamp;
        uint256 tokenAmount;
        uint256 usdtAmount;
        uint256 vestingRate;
    }

    /**
     * @dev Only crowdsale contract functions can call this function. Using for returning vesting stages to crowdsale getVestingList function.
     */
    function getVestingListDetails(
        address _beneficiary,
        uint256 _icoType,
        uint256 _tokenAbsoluteUsdtPrice,
        uint256 _ICOnumberOfVesting
    )
        public
        view
        onlyCrowdsale
        returns (VestingScheduleData[] memory vestingSchedule)
    {
        uint256 size = _ICOnumberOfVesting + 1;
        VestingScheduleData[] memory scheduleArr = new VestingScheduleData[](
            size
        );

        VestingScheduleStruct memory vesting = getBeneficiaryVesting(
            _beneficiary,
            _icoType
        );

        /*require(
            vesting.icoStartDate==0,
            "ERROR at getVestingListDetail: There is no participating user with this address."
        );*/

        uint256 cliffTokenAllocation = (vesting.cliffAndVestingAllocation *
            vesting.unlockRate) / 100;
        uint256 cliffUsdtAllocation = (cliffTokenAllocation *
            _tokenAbsoluteUsdtPrice) / 10**6;
        uint256 cliffUnlockDateTimestamp = vesting.icoStartDate;
        scheduleArr[0] = VestingScheduleData({
            id: 0,
            unlockDateTimestamp: cliffUnlockDateTimestamp,
            tokenAmount: cliffTokenAllocation,
            usdtAmount: cliffUsdtAllocation,
            vestingRate: vesting.unlockRate * 1000
        });

        uint256 vestingRateAfterCliff = (1000 * (100 - vesting.unlockRate)) /
            vesting.numberOfVesting;

        uint256 usdtAmountAfterCliff = (vesting.investedUSDT -
            cliffUsdtAllocation) / _ICOnumberOfVesting;
        uint256 tokenAmountAfterCliff = vesting.vestingAllocation /
            _ICOnumberOfVesting;
        cliffUnlockDateTimestamp += (30 days * vesting.numberOfCliff);
        for (uint256 i = 0; i < vesting.numberOfVesting; ++i) {
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
}
