```mermaid
flowchart TD
    Start([Start Script]) --> Init[Initialize:<br/>Load config.env<br/>Parse arguments]
    
    Init --> ModeDecision{<b>MODE DECISION</b><br/>--incremental flag?}
    
    ModeDecision -->|No| FullBuild[<b>FULL BUILD MODE</b><br/>Process all services<br/>FORCE_ALL = true]
    ModeDecision -->|Yes| IncrementalSetup[<b>INCREMENTAL MODE</b><br/>Get changed files via git]
    
    IncrementalSetup --> CriticalCheck{Critical files changed?<br/>services.txt, template.yaml,<br/>config.env}
    
    CriticalCheck -->|Yes| ForceFull[Override to FULL BUILD<br/>FORCE_ALL = true]
    CriticalCheck -->|No| IncrementalActive[<b>INCREMENTAL ACTIVE</b><br/>Only process changed schemas<br/>FORCE_ALL = false]
    
    FullBuild --> Login[Login to API Connect]
    ForceFull --> Login
    IncrementalActive --> Login
    
    Login --> ServiceLoop[<b>FOR EACH SERVICE</b><br/>in services.txt]
    
    ServiceLoop --> ServiceCondition1{<b>CONDITIONAL 1</b><br/>Incremental mode AND<br/>schema not changed?}
    
    ServiceCondition1 -->|Yes - SKIP| NextService[Skip this service<br/>Continue to next]
    ServiceCondition1 -->|No - PROCESS| ServiceCondition2{<b>CONDITIONAL 2</b><br/>API already exists<br/>in API Connect?}
    
    ServiceCondition2 -->|No| PathCreate[<b>CREATE PATH</b><br/>1. Generate from template<br/>2. Validate<br/>3. Create draft API]
    ServiceCondition2 -->|Yes| PathUpdate[<b>UPDATE PATH</b><br/>1. Get existing API<br/>2. Replace schema<br/>3. Update target-url<br/>4. Validate<br/>5. Update draft API]
    
    PathCreate --> OperationResult{Success?}
    PathUpdate --> OperationResult
    
    OperationResult -->|Yes| IncSuccess[SUCCESS_COUNT++]
    OperationResult -->|No| IncFailure[FAILURE_COUNT++]
    
    IncSuccess --> NextService
    IncFailure --> NextService
    NextService --> ServiceLoop
    
    ServiceLoop -->|All Done| ProductCondition{<b>CONDITIONAL 3</b><br/>Perform Product Update?<br/><br/>Skip if: Incremental mode<br/>AND no APIs updated<br/>SUCCESS_COUNT = 0}
    
    ProductCondition -->|Skip| FinalReport[Display Summary<br/>Skip product publish]
    ProductCondition -->|Perform| ProductFlow[<b>PRODUCT UPDATE</b><br/>1. Collect all APIs<br/>2. Backup existing<br/>3. Merge API lists<br/>4. Generate product YAML<br/>5. Create/Update draft<br/>6. Publish to catalog]
    
    ProductFlow --> ProductResult{Success?}
    ProductResult -->|No| Exit1([Exit with Error])
    ProductResult -->|Yes| FinalReport
    
    FinalReport --> SaveCondition{<b>CONDITIONAL 4</b><br/>Save incremental state?<br/><br/>Only if:<br/>FAILURE_COUNT = 0}
    
    SaveCondition -->|Yes| SaveCommit[Save current git commit<br/>to .last_successful_commit<br/><br/>Used as baseline for<br/>next incremental run]
    SaveCondition -->|No| SkipSave[Skip state save<br/>Keep previous commit hash]
    
    SaveCommit --> End([Success])
    SkipSave --> End
    
    style Start fill:#e1f5e1
    style End fill:#e1f5e1
    style Exit1 fill:#ffe1e1
    
    style ModeDecision fill:#fff3e1,stroke:#ff9800,stroke-width:3px
    style ServiceCondition1 fill:#fff3e1,stroke:#ff9800,stroke-width:3px
    style ServiceCondition2 fill:#fff3e1,stroke:#ff9800,stroke-width:3px
    style ProductCondition fill:#fff3e1,stroke:#ff9800,stroke-width:3px
    style SaveCondition fill:#fff3e1,stroke:#ff9800,stroke-width:3px
    
    style FullBuild fill:#e3f2fd
    style IncrementalActive fill:#e3f2fd
    style PathCreate fill:#f3e5f5
    style PathUpdate fill:#fff9c4
    style ProductFlow fill:#e1f5fe
    ```