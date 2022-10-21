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
    uint256 private totalReleasedAllocation;

    mapping(address => mapping(uint256 => VestingScheduleStruct))
        internal vestingSchedules;

    /**
     * @dev Creates a vesting contract.
     * @param tokenAddress Address of the ERC20 token contract
     */
    constructor(address tokenAddress) {
        require(tokenAddress != address(0x0));
        token = ERC20(tokenAddress);
        totalReleasedAllocation = 0;
    }

    modifier onlyBeneficiaryOrOwner(address _beneficiary) {
        require(
            msg.sender == _beneficiary || msg.sender == owner(),
            "ERROR at release: Only beneficiary and owner can release vested tokens."
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
    event VestingScheduleRevoked(address account);
    event AllocationReleased(address account, uint256 amount);

    struct VestingScheduleStruct {
        address beneficiaryAddress;
        uint256 initializationTime; //block.timestamp.now (vesting schedule initialization time)
        uint256 numberOfCliff; //Number of cliff months
        uint256 numberOfVesting; //Number of vesting months
        uint256 unlockRate; //Initial vesting of beneficiary
        bool isRevocable; // Whether or not the vesting is revocable
        bool revoked; // Whether or not the vesting has been revoked
        uint256 cliffAndVestingAllocation; // Total amount of tokens to be released at the end of the vesting cliff + vesting
        uint256 vestingAllocation; // Total amount of tokens to be released at the end of the vesting only vesting
        bool tgeVested; //Whether or not the tge has been vested
        uint256 releasedPeriod; //Already released months
        uint256 icoType; //Type of ICO  0=>seed, 1=>private
        uint256 investedUSDT; //Beneficiary addresses and their investments
        bool isClaimed; //Shows whether assigned tokens is claimed or not
        uint256 tokenAbsoluteUsdtPrice;
    }

    /**
     * @notice Creates a new vesting schedule.
     * @param _beneficiary Address of the beneficiary
     * @param _numberOfCliffMonths Number of cliff months
     * @param _numberOfVestingMonths Number of vesting months
     * @param _unlockRate Initial vesting rate
     * @param _isRevocable Whether can be revoked or not
     * @param _allocation Total allocation amount
     * @param _IcoType Ico type  0=>seed, 1=>private
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
    ) internal {
        require(
            vestingSchedules[_beneficiary][_IcoType].beneficiaryAddress ==
                address(0x0),
            "ERROR (createVestingSchedule): Schedule already exist."
        );
        require(
            _numberOfCliffMonths > 0,
            "ERROR at createVestingSchedule: Cliff cannot be 0 month"
        );
        require(
            _numberOfVestingMonths > 0,
            "ERROR at createVestingSchedule: Vesting cannot be 0 month"
        );

        uint totalVestingAllocation = (_allocation -
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

    function getBeneficiaryVesting(address beneficiary, uint icoType)
        public
        view
        returns (VestingScheduleStruct memory)
    {
        require(
            vestingSchedules[beneficiary][icoType].beneficiaryAddress !=
                address(0),
            "ERROR at getBeneficiaryVesting: There is no participating user with this address."
        );
        return vestingSchedules[beneficiary][icoType];
    }

    /**
     * @notice Revokes given vesting schedule.
     * @param _beneficiary Address of the beneficiary.
     * @param _icoType Ico type
     */
    function revoke(address _beneficiary, uint256 _icoType) external onlyOwner {
        require(
            vestingSchedules[_beneficiary][_icoType].beneficiaryAddress !=
                address(0x0),
            "ERROR: Vesting Schedule already exist."
        );
        require(
            vestingSchedules[_beneficiary][_icoType].isRevocable,
            "ERROR at revoke: Target schedule is not revokable."
        );
        require(
            !vestingSchedules[_beneficiary][_icoType].revoked,
            "ERROR at revoked: Vesting Schedule is already revoked."
        );

        release(_beneficiary, _icoType);
        vestingSchedules[_beneficiary][_icoType].revoked = true;
        emit VestingScheduleRevoked(_beneficiary);
    }

    /**
     * @notice Release vested tokens of the beneficiary.
     * @param _beneficiary Address of the beneficiary.
     * @param _icoType Type of the ICO.
     */
    function release(address _beneficiary, uint256 _icoType)
        internal
        onlyBeneficiaryOrOwner(_beneficiary)
    {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            !vestingSchedule.revoked,
            "ERROR at release: Vesting Schedule is revoked."
        );

        uint256 releasableAmount = getReleasableAmount(_beneficiary, _icoType);

        require(
            releasableAmount > 0,
            "ERROR at release: Releasable amount is 0."
        );

        address payable beneficiaryAccount = payable(
            vestingSchedule.beneficiaryAddress
        );

        token.safeTransferFrom(owner(), beneficiaryAccount, releasableAmount);
        totalReleasedAllocation += releasableAmount;
        emit AllocationReleased(_beneficiary, releasableAmount);
    }

    /**
     * @notice Calculates the vested amount of given vesting schedule.
     * @param _beneficiary Beneficiary vesting schedule struct.
     * @param _icoType Beneficiary vesting schedule struct.
     */
    function getReleasableAmount(address _beneficiary, uint256 _icoType)
        internal
        returns (uint256)
    {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.initializationTime != 0,
            "vesting does not exist !"
        );

        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "You claimed all of your vesting."
        );
        uint256 releasableAmount = 0;

        uint256 currentTime = block.timestamp;
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );
        require(
            elapsedMonthNumber >= vestingSchedule.numberOfCliff,
            "Cliff time is not ended yet."
        );
        //require(elapsedMonthNumber>=0,"elapsedMonthNumber is negative");
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
        //require(vestedMonthNumber>=0,"vestedMonthNumber is negative");

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

    function viewReleasableAmount(address _beneficiary, uint256 _icoType)
        public
        view
        returns (uint256)
    {
        VestingScheduleStruct memory vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.initializationTime != 0,
            "vesting does not exist !"
        );

        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "You claimed all of your vesting."
        );
        uint256 releasableAmount = 0;

        uint256 currentTime = block.timestamp;
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );
        require(
            elapsedMonthNumber >= vestingSchedule.numberOfCliff,
            "Cliff time is not ended yet."
        );
        //require(elapsedMonthNumber>=0,"elapsedMonthNumber is negative");
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
        //require(vestedMonthNumber>=0,"vestedMonthNumber is negative");

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
     * @notice Get invested amount of USDT of vesting schedule by using beneficiary address and ico type
     * @param _beneficiary Beneficiary vesting schedule struct.
     * @param _icoType Beneficiary vesting schedule struct.
     */
    function getReleasableUsdtAmount(address _beneficiary, uint256 _icoType)
        internal
        returns (uint256)
    {
        VestingScheduleStruct storage vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.initializationTime != 0,
            "vesting does not exist !"
        );

        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "You claimed all of your vesting."
        );
        uint256 releasableUsdtAmount = 0;

        uint256 currentTime = block.timestamp;
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );
        require(
            elapsedMonthNumber >= vestingSchedule.numberOfCliff,
            "Cliff time is not ended yet."
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

    function viewReleasableUsdtAmount(address _beneficiary, uint256 _icoType)
        public
        view
        returns (uint256)
    {
        VestingScheduleStruct memory vestingSchedule = vestingSchedules[
            _beneficiary
        ][_icoType];

        require(
            vestingSchedule.initializationTime != 0,
            "vesting does not exist !"
        );

        require(
            vestingSchedule.releasedPeriod < vestingSchedule.numberOfVesting,
            "You claimed all of your vesting."
        );
        uint256 releasableUsdtAmount = 0;

        uint256 currentTime = block.timestamp;
        uint256 elapsedMonthNumber = _getElapsedMonth(
            vestingSchedule,
            currentTime
        );
        require(
            elapsedMonthNumber >= vestingSchedule.numberOfCliff,
            "Cliff time is not ended yet."
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
     * @notice Calculates the elapsed month of the given schedule so far.
     * @param vestingSchedule Beneficiary vesting schedule struct.
     * @param currentTime Given by parameter to avoid transaction call latency.
     */
    function _getElapsedMonth(
        VestingScheduleStruct memory vestingSchedule,
        uint256 currentTime
    ) internal pure returns (uint256) {
        return (currentTime - vestingSchedule.initializationTime) / (300);
    }

    /**
     * @notice Get token allocation of vesting schedule by using beneficiary address and ico type
     * @param _beneficiary Beneficiary vesting schedule struct.
     * @param _icoType Beneficiary vesting schedule struct.
     */
    function getScheduleTokenAllocation(address _beneficiary, uint256 _icoType)
        external
        view
        returns (uint256)
    {
        return
            vestingSchedules[_beneficiary][_icoType].cliffAndVestingAllocation;
    }

    function updateVestingStartDate(
        uint256 startDate,
        uint256 _icoType,
        address beneficiary
    ) external onlyOwner {
        vestingSchedules[beneficiary][_icoType].initializationTime = startDate;
    }

    /**
     * @notice Deletes vesting schedule by using beneficiary address and ico type
     * @param _beneficiary Beneficiary vesting schedule struct.
     * @param _icoType Beneficiary vesting schedule struct.
     
    function deleteSchedule(address _beneficiary, uint256 _icoType) external {
        totalAllocation -= vestingSchedules[_beneficiary][_icoType].allocation;
        delete vestingSchedules[_beneficiary][_icoType];
    }
    */
}
