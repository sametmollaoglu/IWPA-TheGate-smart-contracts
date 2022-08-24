// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vesting is Ownable{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //Address of the ERC20 token
    IERC20 immutable private token;
    uint256 private totalAllocation;
    uint256 private totalReleasedAllocation;
    mapping( address => VestingScheduleStruct ) private vestingSchedules;

    /**
     * @dev Creates a vesting contract.
     * @param tokenAddress Address of the ERC20 token contract
     */
    constructor(address tokenAddress){
        require(tokenAddress != address(0x0));
        token = IERC20(tokenAddress);
        totalAllocation=0;
        totalReleasedAllocation=0;
    }

    modifier onlyBeneficiaryOrOwner(address _beneficiary) {
        require(
            msg.sender == _beneficiary || msg.sender == owner(),
            "ERROR at release: Only beneficiary and owner can release vested tokens."
        );
        _;
    }

    event VestingScheduleAdded(address beneficiary, uint256 numberOfCliffMonths, uint256 numberOfVestingMonths, uint256 unlockRate, bool isRevocable, uint256 allocation);
    event VestingScheduleRevoked(address account);
    event AllocationReleased(address account, uint256 amount);

    struct VestingScheduleStruct{
        address beneficiaryAddress;
        uint256 initializationTime; //block.timestamp.now (vesting schedule initialization time)
        uint256 numberOfCliff; //Number of cliff months
        uint256 numberOfVesting; //Number of vesting months
        uint256 unlockRate; //Initial vesting of beneficiary
        bool isRevocable; // Whether or not the vesting is revocable
        bool revoked; // Whether or not the vesting has been revoked
        uint256 allocation; // Total amount of tokens to be released at the end of the vesting
        bool tgeVested; //Whether or not the tge has been vested
        uint256 releasedPeriod; //Already released months
    }

    /**
    * @notice Creates a new vesting schedule.
    * @param _beneficiary Address of the beneficiary
    * @param _numberOfCliffMonths Number of cliff months
    * @param _numberOfVestingMonths Number of vesting months
    * @param _unlockRate Initial vesting rate
    * @param _isRevocable Whether can be revoked or not
    * @param _allocation Total allocation amount
    */
    function createVestingSchedule(address _beneficiary, uint256 _numberOfCliffMonths, uint256 _numberOfVestingMonths, uint8 _unlockRate, bool _isRevocable, uint256 _allocation) external onlyOwner{
        require(vestingSchedules[_beneficiary].beneficiaryAddress==address(0x0),"ERROR (createVestingSchedule): Schedule already exist." );
        require(totalAllocation + _allocation <= token.balanceOf(address(this)),"ERROR at createVestingSchedule: Cannot create vesting schedule because not sufficient tokens");
        require(_numberOfCliffMonths > 0,"ERROR at createVestingSchedule: Cliff cannot be 0 month");
        require(_numberOfVestingMonths > 0,"ERROR at createVestingSchedule: Vesting cannot be 0 month");
        require(_allocation > 0, "ERROR at createVestingSchedule: Allocation must be > 0");

        vestingSchedules[_beneficiary] = VestingScheduleStruct(
            _beneficiary,
            block.timestamp,
            _numberOfCliffMonths,
            _numberOfVestingMonths,
            _unlockRate,
            _isRevocable,
            false,
            _allocation,
            false,
            0
        );

        totalAllocation+=_allocation;
        emit VestingScheduleAdded(_beneficiary, _numberOfCliffMonths, _numberOfVestingMonths, _unlockRate, _isRevocable, _allocation);
    }

    /**
    * @notice Revokes given vesting schedule.
    * @param _beneficiary Address of the beneficiary.
    */
    function revoke(address _beneficiary) external onlyOwner{
        require(vestingSchedules[_beneficiary].beneficiaryAddress!=address(0x0),"ERROR: Vesting Schedule already exists" );
        require(vestingSchedules[_beneficiary].isRevocable, "ERROR at revoke: Target schedule is not revokable.");
        require(!vestingSchedules[_beneficiary].revoked,"ERROR at revoked: Vesting Schedule is already revoked.");

        release(_beneficiary);
        vestingSchedules[_beneficiary].revoked=true;
        emit VestingScheduleRevoked(_beneficiary);
    }

    /**
    * @notice Release vested tokens of the beneficiary.
    * @param _beneficiary Address of the beneficiary.
    */
    function release(address _beneficiary) public onlyBeneficiaryOrOwner(_beneficiary){
        require(!vestingSchedules[_beneficiary].revoked,"ERROR at release: Vesting Schedule is revoked.");

        VestingScheduleStruct storage vestingSchedule = vestingSchedules[_beneficiary];

        uint256 releasableAmount=_getReleasableAmount(vestingSchedule);
        
        require(releasableAmount>0,"ERROR at release: Releasable amount is 0 wait for vesting.");

        address payable beneficiaryAccount = payable(vestingSchedule.beneficiaryAddress);
        totalReleasedAllocation += releasableAmount;
        token.safeTransfer(beneficiaryAccount, releasableAmount);
        emit AllocationReleased(_beneficiary, releasableAmount);
    }

    /**
    * @notice Calculates the vested amount of given vesting schedule.
    * @param vestingSchedule Beneficiary vesting schedule struct.
    */
    function _getReleasableAmount(VestingScheduleStruct memory vestingSchedule) internal view returns(uint256){
        uint256 currentTime= block.timestamp;
        uint256 releasableAmount=0;
        uint256 vestedMonthNumber=_getElapsedMonth(vestingSchedule, currentTime)-vestingSchedule.releasedPeriod-vestingSchedule.numberOfCliff;
        
        if(!vestingSchedule.tgeVested){
            releasableAmount+=(vestingSchedule.unlockRate * vestingSchedule.allocation /100);
            vestingSchedule.tgeVested=true;
        }
        if(vestedMonthNumber>0){
            vestingSchedule.releasedPeriod += vestedMonthNumber;
            releasableAmount += ((vestingSchedule.allocation/vestingSchedule.numberOfVesting) * vestedMonthNumber);
        }
        return releasableAmount;
    }

    /**
    * @notice Calculates the elapsed month of the given schedule so far.
    * @param vestingSchedule Beneficiary vesting schedule struct.
    * @param currentTime Given by parameter to avoid transaction call latency.
    */
    function _getElapsedMonth(VestingScheduleStruct memory vestingSchedule, uint256 currentTime) internal pure returns(uint256){
        return (currentTime - vestingSchedule.initializationTime) / 30 seconds;
    }
}
