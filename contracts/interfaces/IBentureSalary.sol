// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "./errors/IBentureSalaryErrors.sol";

/// @title An interface of a Salary contract.
interface IBentureSalary is IBentureSalaryErrors {
    struct SalaryInfo {
        uint256 id;
        uint256 periodDuration;
        uint256 amountOfPeriods;
        uint256 amountOfWithdrawals;
        address tokenAddress;
        uint256[] tokensAmountPerPeriod;
        uint256 lastWithdrawalTime;
        uint256 salaryStartTime;
        address employer;
        address employee;
    }

    /// @notice Returns the name of employee.
    /// @param employeeAddress Address of employee.
    /// @return name The name of employee.
    function getNameOfEmployee(
        address employeeAddress
    ) external view returns (string memory name);

    /// @notice Returns the array of admins of employee.
    /// @param employeeAddress Address of employee.
    /// @return admins The array of admins of employee.
    function getAdminsByEmployee(
        address employeeAddress
    ) external view returns (address[] memory admins);

    /// @notice Sets new or changes current name of the employee.
    /// @param employeeAddress Address of employee.
    /// @param name New name of employee.
    /// @dev Only admin can call this method.
    function setNameToEmployee(
        address employeeAddress,
        string memory name
    ) external;

    /// @notice Removes name from employee.
    /// @param employeeAddress Address of employee.
    /// @dev Only admin can call this method.
    function removeNameFromEmployee(address employeeAddress) external;

    /// @notice Adds new employee.
    /// @param employeeAddress Address of employee.
    /// @dev Only admin can call this method.
    function addEmployee(address employeeAddress) external;

    /// @notice Removes employee.
    /// @param employeeAddress Address of employee.
    /// @dev Only admin can call this method.
    function removeEmployee(address employeeAddress) external;

    /// @notice Withdraws all of employee's salary.
    /// @dev Anyone can call this method. No restrictions.
    function withdrawAllSalaries() external;

    /// @notice Withdraws employee's salary.
    /// @param salaryId IDs of employee salaries.
    /// @dev Anyone can call this method. No restrictions.
    function withdrawSalary(uint256 salaryId) external;

    /// @notice Returns the array of employees of admin.
    /// @param adminAddress Address of admin.
    /// @return employees The array of employees of admin.
    function getEmployeesByAdmin(
        address adminAddress
    ) external view returns (address[] memory employees);

    /// @notice Returns true if user if employee for admin and False if not.
    /// @param adminAddress Address of admin.
    /// @param employeeAddress Address of employee.
    /// @return isEmployee True if user if employee for admin. False if not.
    function checkIfUserIsEmployeeOfAdmin(
        address adminAddress,
        address employeeAddress
    ) external view returns (bool isEmployee);

    /// @notice Returns true if user is admin for employee and False if not.
    /// @param employeeAddress Address of employee.
    /// @param adminAddress Address of admin.
    /// @return isAdmin True if user is admin for employee. False if not.
    function checkIfUserIsAdminOfEmployee(
        address employeeAddress,
        address adminAddress
    ) external view returns (bool isAdmin);

    /// @notice Returns array of salaries of employee.
    /// @param employeeAddress Address of employee.
    /// @return salaries Array of salaries of employee.
    function getSalariesIdByEmployeeAndAdmin(
        address employeeAddress,
        address adminAddress
    ) external view returns (uint256[] memory salaries);

    /// @notice Returns salary by ID.
    /// @param salaryId Id of SalaryInfo.
    /// @return salary SalaryInfo by ID.
    function getSalaryById(
        uint256 salaryId
    ) external view returns (SalaryInfo memory salary);

    /// @notice Removes periods from salary
    /// @param salaryId ID of target salary
    /// @param amountOfPeriodsToDelete Amount of periods to delete from salary
    /// @dev Only admin can call this method.
    function removePeriodsFromSalary(
        uint256 salaryId,
        uint256 amountOfPeriodsToDelete
    ) external;

    /// @notice Adds periods to salary
    /// @param salaryId ID of target salary
    /// @param tokensAmountPerPeriod Array of periods to add to salary
    /// @dev Only admin can call this method.
    function addPeriodsToSalary(
        uint256 salaryId,
        uint256[] memory tokensAmountPerPeriod
    ) external;

    /// @notice Adds salary to employee.
    /// @param employeeAddress Address of employee.
    /// @param periodDuration Duration of one period.
    /// @param amountOfPeriods Amount of periods.
    /// @param tokensAmountPerPeriod Amount of tokens per period.
    /// @dev Only admin can call this method.
    function addSalaryToEmployee(
        address employeeAddress,
        uint256 periodDuration,
        uint256 amountOfPeriods,
        address tokenAddress,
        uint256[] memory tokensAmountPerPeriod
    ) external;

    /// @notice Returns amount of pending salary.
    /// @param salaryId Salary ID.
    /// @return salaryAmount Amount of pending salary.
    function getSalaryAmount(
        uint256 salaryId
    ) external view returns (uint256 salaryAmount);

    /// @notice Removes salary from employee.
    /// @param salaryId ID of employee salary.
    /// @dev Only admin can call this method.
    function removeSalaryFromEmployee(uint256 salaryId) external;

    /// @notice Emits when user was added to Employees of Admin
    event EmployeeAdded(
        address indexed employeeAddress,
        address indexed adminAddress
    );

    /// @notice Emits when user was removed from Employees of Admin
    event EmployeeRemoved(
        address indexed employeeAddress,
        address indexed adminAddress
    );

    /// @notice Emits when Employee's name was added or changed
    event EmployeeNameChanged(
        address indexed employeeAddress,
        string indexed name
    );

    /// @notice Emits when name was removed from Employee
    event EmployeeNameRemoved(address indexed employeeAddress);

    /// @notice Emits when salary was added to Employee
    event EmployeeSalaryAdded(
        address indexed employeeAddress,
        address indexed adminAddress,
        SalaryInfo indexed salary
    );

    /// @notice Emits when salary was removed from Employee
    event EmployeeSalaryRemoved(
        address indexed employeeAddress,
        address indexed adminAddress,
        SalaryInfo indexed salary
    );

    /// @notice Emits when Employee withdraws salary
    event EmployeeSalaryClaimed(
        address indexed employeeAddress,
        address indexed adminAddress,
        SalaryInfo indexed salary
    );

    /// @notice Emits when Admin adds periods to salary
    event SalaryPeriodsAdded(
        address indexed employeeAddress,
        address indexed adminAddress,
        SalaryInfo indexed salary
    );

    /// @notice Emits when Admin removes periods from salary
    event SalaryPeriodsRemoved(
        address indexed employeeAddress,
        address indexed adminAddress,
        SalaryInfo indexed salary
    );
}
