```mermaid
flowchart TD
    Start([Start]) --> LoadConfig[Load Configuration]
    LoadConfig --> CheckPrereq{Prerequisites OK?}
    CheckPrereq -->|No| Error1[Error: Missing Tools]
    CheckPrereq -->|Yes| ParseArgs[Parse Arguments]
    
    ParseArgs --> ModeCheck{Incremental Mode?}
    ModeCheck -->|No| FullBuild[Set FORCE_ALL = true]
    ModeCheck -->|Yes| GetChanges[Get Changed Files]
    
    GetChanges --> ConfigChanged{Config Changed?}
    ConfigChanged -->|Yes| ForceAll[Set FORCE_ALL = true]
    ConfigChanged -->|No| IncrementalOK[Incremental Active]
    
    FullBuild --> Login
    ForceAll --> Login
    IncrementalOK --> Login
    
    Login[Login to API Connect] --> LoginSuccess{Login Success?}
    LoginSuccess -->|No| Error2[Error: Login Failed]
    LoginSuccess -->|Yes| ValidateNames[Validate Unique API Names]
    
    ValidateNames --> NamesUnique{Names Unique?}
    NamesUnique -->|No| Error3[Error: Duplicates]
    NamesUnique -->|Yes| InitLoop[Initialize Counters]
    
    InitLoop --> LoopStart{More Services?}
    
    LoopStart -->|No| LoopEnd[Processing Complete]
    LoopStart -->|Yes| ReadService[Read Service Data]
    
    ReadService --> IncrementalCheck{Skip in Incremental?}
    IncrementalCheck -->|Yes| SkipService[Skip Service]
    IncrementalCheck -->|No| AddToRefs[Add to API_REFS]
    
    SkipService --> LoopStart
    AddToRefs --> CheckExists[Check API Exists]
    
    CheckExists --> APIExists{API Exists?}
    
    APIExists -->|No| LoadSchemaNew{Schema Provided?}
    APIExists -->|Yes| LoadSchemaUpdate{Schema Provided?}
    
    LoadSchemaNew -->|Yes| ConvertSchemaNew[Convert JSON to YAML]
    LoadSchemaNew -->|No| EmptySchemaNew[Use Empty Schema]
    
    ConvertSchemaNew --> CreatePath[PATH A: CREATE]
    EmptySchemaNew --> CreatePath
    
    CreatePath --> GenYAML[Generate from Template]
    GenYAML --> InsertSchema[Insert Schema]
    InsertSchema --> ValidateNew[Validate YAML]
    
    ValidateNew --> ValidNew{Valid?}
    ValidNew -->|No| FailNew[Increment FAILURE]
    ValidNew -->|Yes| CreateAPI[Create Draft API]
    
    CreateAPI --> CreateSuccess{Success?}
    CreateSuccess -->|No| FailCreate[Increment FAILURE]
    CreateSuccess -->|Yes| SuccessCreate[Increment SUCCESS]
    
    FailNew --> LoopStart
    FailCreate --> LoopStart
    SuccessCreate --> LoopStart
    
    LoadSchemaUpdate -->|Yes| ConvertSchemaUpdate[Convert JSON to YAML]
    LoadSchemaUpdate -->|No| EmptySchemaUpdate[Use Empty Schema]
    
    ConvertSchemaUpdate --> UpdatePath[PATH B: UPDATE]
    EmptySchemaUpdate --> UpdatePath
    
    UpdatePath --> GetExisting[Download Existing API]
    GetExisting --> DetectOp[Detect Operation Name]
    
    DetectOp --> SchemaExistsCheck{Schema Exists?}
    
    SchemaExistsCheck -->|Yes + New| ReplaceSchema[Replace Schema]
    SchemaExistsCheck -->|No + New| InsertNewSchema[Insert Schema]
    SchemaExistsCheck -->|Yes + Empty| BackupReplace[Backup and Replace]
    SchemaExistsCheck -->|No + Empty| InsertEmpty[Insert Empty Schema]
    
    ReplaceSchema --> UpdateURL
    InsertNewSchema --> UpdateURL
    BackupReplace --> UpdateURL
    InsertEmpty --> UpdateURL
    
    UpdateURL[Update Target URL] --> ValidateUpdate[Validate YAML]
    
    ValidateUpdate --> ValidUpdate{Valid?}
    ValidUpdate -->|No| FailUpdate[Increment FAILURE]
    ValidUpdate -->|Yes| UpdateAPI[Update Draft API]
    
    UpdateAPI --> UpdateSuccess{Success?}
    UpdateSuccess -->|No| FailUpdateAPI[Increment FAILURE]
    UpdateSuccess -->|Yes| SuccessUpdate[Increment SUCCESS]
    
    FailUpdate --> LoopStart
    FailUpdateAPI --> LoopStart
    SuccessUpdate --> LoopStart
    
    LoopEnd --> ShowSummary[Display Summary]
    
    ShowSummary --> ProductCheck{Update Product?}
    ProductCheck -->|No| SkipProduct[Skip Product]
    ProductCheck -->|Yes| BackupProduct[Backup Product]
    
    BackupProduct --> ProductExists{Product Exists?}
    ProductExists -->|Yes| MergeAPIs[Merge APIs]
    ProductExists -->|No| UseNewAPIs[Use New APIs]
    
    MergeAPIs --> CheckFiles[Check Missing Files]
    UseNewAPIs --> CheckFiles
    
    CheckFiles --> GenProduct[Generate Product YAML]
    GenProduct --> CreateUpdateProd[Create or Update Product]
    
    CreateUpdateProd --> ProdSuccess{Success?}
    ProdSuccess -->|No| ErrorProd[Error: Product Failed]
    ProdSuccess -->|Yes| PublishProd[Publish to Catalog]
    
    PublishProd --> PubSuccess{Success?}
    PubSuccess -->|No| ErrorPub[Error: Publish Failed]
    PubSuccess -->|Yes| SuccessProd[Product Published]
    
    SkipProduct --> Finalize
    SuccessProd --> Finalize
    
    Finalize[Finalize Backup] --> SaveState{All Successful?}
    
    SaveState -->|Yes| SaveCommit[Save Git Hash]
    SaveState -->|No| NoSave[Do Not Save State]
    
    SaveCommit --> Complete
    NoSave --> Complete
    
    Complete([End])
    
    Error1 --> Exit([Exit Error])
    Error2 --> Exit
    Error3 --> Exit
    ErrorProd --> Exit
    ErrorPub --> Exit
    
    style Start fill:#90EE90
    style Complete fill:#90EE90
    style Exit fill:#FFB6C6
    style Error1 fill:#FFB6C6
    style Error2 fill:#FFB6C6
    style Error3 fill:#FFB6C6
    style ErrorProd fill:#FFB6C6
    style ErrorPub fill:#FFB6C6
    style CreatePath fill:#E6F3FF
    style UpdatePath fill:#FFF4E6
    style ProductCheck fill:#F0E6FF
    ```