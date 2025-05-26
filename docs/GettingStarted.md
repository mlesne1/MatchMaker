# 

# What is MatchMaker ?

MatchMaker is a custom matchmaking system designed for Roblox experiences that need flexibility, reliability, and real-time coordination. It leverages Promises for clean, asynchronous flows and uses MemoryStore to share data instantly across servers—making it ideal for multiplayer games with party-based queues, regional distribution, and private server transitions. This tool focuses on predictability and scalability without relying on third-party services or polling workarounds.

# Installation


Make sure your game includes the following folders:

- **`ReplicatedStorage/Utils`**  
  This folder should contain the required utility modules (`Promise`, `Signal`, etc.).

- **`ServerScriptService/MatchMakerPackage`**  
  This should include the MatchMaker module files (`MatchMaker`, `RegionalQueue`, `PrivateServer`, etc.).

> You can organize and customize submodules as needed, but these are required for the system to initialize and run properly.

You can test the MatchMaker system right away using this [**Template Place**](https://www.roblox.com/games/131765851319441/MatchMaker-Template-Place)