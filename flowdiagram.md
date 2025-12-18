```mermaid
flowchart TD
    Start([Start Script]) --> LoadConfig[Load Configuration]
    LoadConfig --> InitVars[Initialize Variables and Directories]
    InitVars --> SetupTrap[Setup Cleanup Trap]
    SetupTrap --> CheckCmds{Check Required Commands}
    
    CheckCmds -->|Missing| Error1[Error: apic/python3 not found]
    Error1 --> Exit1([Exit 1])
    CheckCmds -->|OK| ParseArgs[Parse Command Line Arguments]
    
    ParseArgs --> ModeCheck{Build Mode?}
    ModeCheck -->|Incremental| CheckGit{Git Available?}
    ModeCheck -->|Full Build| SetFullMode[Set FORCE_ALL = true]
    
    CheckGit -->|No| Exit2([Exit 1])
    CheckGit -->|Yes| GetChanges[Get Changed Files Since Last Commit]
    GetChanges --> CheckConfig{Config Files Changed?}
    
    CheckConfig -->|Yes| ForceAll[Set FORCE_ALL = true]
    CheckConfig -->|No| CheckEmpty{Any Changes?}
    CheckEmpty -->|No| CheckCommitFile{Last Commit File Exists?}
    CheckCommitFile -->|Yes| SetIncremental[Incremental Mode Active]
    CheckCommitFile -->|No| ForceAll
    CheckEmpty -->|Yes| SetIncremental
    
    ForceAll --> DetectAPIC
    SetFullMode --> DetectAPIC
    SetIncremental --> DetectAPIC
    
    DetectAPIC[Detect APIC Executable] --> Login[Login to APIC via SSO]
    
    Login -->|Failed| Exit3([Exit 1])
    Login -->|Success| StartLoop[Start Processing services.txt]
    
    StartLoop --> ReadLine[Read Service Line]
    ReadLine --> ValidLine{Valid Line?}
    
    ValidLine -->|Blank/Comment| ReadLine
    ValidLine -->|Valid| ParseService[Parse Service Data]
    
    ParseService --> IncrementalCheck{Incremental Mode Active?}
    IncrementalCheck -->|Yes| SchemaChanged{Schema File Changed?}
    SchemaChanged -->|No| Skip[Skip Service]
    Skip --> MoreServices
    SchemaChanged -->|Yes| CheckExists
    IncrementalCheck -->|No| CheckExists
    
    CheckExists[Check if API Exists] --> APIExists{API Exists?}
    
    APIExists -->|Yes| SetExists[API_EXISTS = true]
    APIExists -->|No| SetNew[API_EXISTS = false]
    
    SetExists --> LoadSchema1
    SetNew --> LoadSchema1
    
    LoadSchema1{Schema Provided?}
    LoadSchema1 -->|Yes| ConvertSchema[Convert JSON Schema to YAML]
    LoadSchema1 -->|No| EmptySchema[Use Empty Object Schema]
    
    ConvertSchema --> PathBranch
    EmptySchema --> PathBranch
    
    PathBranch{API_EXISTS?}
    
    PathBranch -->|false - Create New| GenTemplate[Generate YAML from Template]
    GenTemplate --> ReplaceSchema[Replace Schema Placeholder]
    ReplaceSchema --> Validate1[Validate YAML]
    
    Validate1 -->|Failed| Fail1[Increment FAILURE_COUNT]
    Fail1 --> Cleanup1[Cleanup Temp Files]
    Cleanup1 --> MoreServices
    
    Validate1 -->|Success| CreateAPI[Create Draft API]
    CreateAPI -->|Failed| Fail2[Increment FAILURE_COUNT]
    CreateAPI -->|Success| Success1[Increment SUCCESS_COUNT]
    
    Fail2 --> Cleanup2[Cleanup Temp Files]
    Success1 --> Cleanup2
    Cleanup2 --> MoreServices
    
    PathBranch -->|true - Update Existing| ReplaceSchemaSection[Replace Schema Section in Existing YAML]
    ReplaceSchemaSection --> UpdateURL[Update Target URL]
    UpdateURL --> Validate2[Validate Updated YAML]
    
    Validate2 -->|Failed| Fail3[Increment FAILURE_COUNT]
    Fail3 --> Cleanup3[Cleanup Temp Files]
    Cleanup3 --> MoreServices
    
    Validate2 -->|Success| UpdateAPI[Update Draft API]
    UpdateAPI -->|Failed| Fail4[Increment FAILURE_COUNT]
    UpdateAPI -->|Success| Success2[Increment SUCCESS_COUNT]
    
    Fail4 --> Cleanup4[Cleanup Temp Files]
    Success2 --> Cleanup4
    Cleanup4 --> MoreServices
    
    MoreServices{More Services?}
    MoreServices -->|Yes| ReadLine
    MoreServices -->|No| CheckProduct
    
    CheckProduct{Should Update Product?}
    CheckProduct -->|No Updates in Incremental| SkipProduct[Skip Product Update]
    CheckProduct -->|Yes| CollectAPIs[Collect All API References]
    
    CollectAPIs --> BackupProduct[Backup Existing Product]
    BackupProduct --> ProductExists{Product Exists?}
    
    ProductExists -->|Yes| MergeAPIs[Merge Existing and New APIs]
    ProductExists -->|No| UseNewAPIs[Use Only New APIs]
    
    MergeAPIs --> GenProduct
    UseNewAPIs --> GenProduct
    
    GenProduct[Generate Product YAML] --> UpdateProduct[Try Update Product]
    
    UpdateProduct -->|Failed| CreateProduct[Create New Product]
    UpdateProduct -->|Success| PublishProduct
    CreateProduct -->|Failed| Exit4([Exit 1])
    CreateProduct -->|Success| PublishProduct
    
    PublishProduct[Publish to Catalog] -->|Failed| Exit5([Exit 1])
    PublishProduct -->|Success| Finalize
    
    SkipProduct --> Finalize
    
    Finalize[Finalize Backup] --> SaveState{No Failures?}
    
    SaveState -->|Yes| SaveCommit[Save Git Commit Hash]
    SaveState -->|No| DisplaySummary
    SaveCommit --> DisplaySummary
    
    DisplaySummary[Display Summary] --> End([Script Complete])
    
    style Start fill:#90EE90
    style End fill:#90EE90
    style Exit1 fill:#FFB6C1
    style Exit2 fill:#FFB6C1
    style Exit3 fill:#FFB6C1
    style Exit4 fill:#FFB6C1
    style Exit5 fill:#FFB6C1
    style PathBranch fill:#FFE4B5
    style ModeCheck fill:#FFE4B5
    style CheckProduct fill:#FFE4B5
    ```