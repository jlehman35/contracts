// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

// Utils
import "../../extension/Multicall.sol";
import "../../openzeppelin-presets/proxy/Clones.sol";
import "../../openzeppelin-presets/utils/structs/EnumerableSet.sol";
import "../utils/BaseAccount.sol";

// Interface
import "../interfaces/IEntrypoint.sol";
import "../interfaces/IAccountFactory.sol";

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

abstract contract BaseAccountFactory is IAccountFactory, Multicall {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*///////////////////////////////////////////////////////////////
                                State
    //////////////////////////////////////////////////////////////*/

    address public immutable accountImplementation;

    mapping(address => EnumerableSet.AddressSet) internal accountsOfSigner;
    mapping(address => EnumerableSet.AddressSet) internal signersOfAccount;

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address _accountImpl) {
        accountImplementation = _accountImpl;
    }

    /*///////////////////////////////////////////////////////////////
                        External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a new Account for admin.
    function createAccount(address _admin, bytes calldata _data) external virtual returns (address);

    /// @notice Callback function for an Account to register its signers.
    function addSigner(address _signer) external {
        address account = msg.sender;

        bool isAlreadyAccount = accountsOfSigner[_signer].add(account);
        bool isAlreadySigner = signersOfAccount[account].add(_signer);

        if (!isAlreadyAccount || !isAlreadySigner) {
            revert("AccountFactory: signer already added");
        }

        emit SignerAdded(account, _signer);
    }

    /// @notice Callback function for an Account to un-register its signers.
    function removeSigner(address _signer) external {
        address account = msg.sender;

        bool isAccount = accountsOfSigner[_signer].remove(account);
        bool isSigner = signersOfAccount[account].remove(_signer);

        if (!isAccount || !isSigner) {
            revert("AccountFactory: signer not found");
        }

        emit SignerRemoved(account, _signer);
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of an Account that would be deployed with the given admin signer.
    function getAddress(address _adminSigner) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(_adminSigner));
        return Clones.predictDeterministicAddress(accountImplementation, salt);
    }

    /// @notice Returns all signers of an account.
    function getSignersOfAccount(address account) external view returns (address[] memory signers) {
        return signersOfAccount[account].values();
    }

    /// @notice Returns all accounts that the given address is a signer of.
    function getAccountsOfSigner(address signer) external view returns (address[] memory accounts) {
        return accountsOfSigner[signer].values();
    }
}