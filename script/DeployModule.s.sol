// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { RegistryDeployer } from "modulekit/modulekit/deployment/RegistryDeployer.sol";

// Import modules here
import { AssetBalancerModule } from "../src/executors/AssetBalancerModule.sol";

/// @title DeployModuleScript
contract DeployModuleScript is Script, RegistryDeployer {
    function run() public {
        // Setup module bytecode, deploy params, and data
        bytes memory bytecode = type(AssetBalancerModule).creationCode;
        bytes memory deployParams = hex'0000000000000000000000006e2dc0f9db014ae19888f539e59285d2ea04244c0000000000000000000000001ec30eade8ee90107acd50b49aebe112132416fc000000000000000000000000354c496bc44d89a24e1d30d232f05a8e34d4fbc5';
        bytes memory data = "";

        // Get private key for deployment
        vm.startBroadcast(vm.envUint("PK"));

        // Deploy module
        address module = deployModule({
            code: bytecode,
            deployParams: deployParams,
            salt: bytes32(0),
            data: data
        });

        // Stop broadcast and log module address
        vm.stopBroadcast();
        console.log("Module deployed at: %s", module);
    }
}
