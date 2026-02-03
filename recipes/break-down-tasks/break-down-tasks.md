# Break Down Tasks

Use beads to create implementation tasks from the design document.

## Task Creation Guidelines

For each major component, feature, or concern identified in the design:

### 1. Understand the Design
- Read the design document thoroughly
- Identify distinct areas of work
- Note dependencies between components

### 2. Create Granular Tasks
- Each task should represent 2-4 hours of focused work
- Tasks should be completable independently or in a clear sequence
- Include specific acceptance criteria from the design

### 3. Use Beads to Create Tasks
```bash
# Example: Create a task for implementing a component
bd create "Implement user authentication model"
```

Each task should have:
- **Title**: Clear, action-oriented description
- **Description**: Reference to relevant design section, specific requirements
- **Acceptance criteria**: From the design's verification strategy
- **Dependencies**: Related tasks or prerequisite work

### 4. Order Tasks Logically
- Infrastructure/data model tasks before feature tasks
- Tests should be created alongside implementation
- Dependencies should be explicit

## Tracking Template

For each task created:
- Title and task ID
- Design section it implements
- Estimated complexity (simple/medium/complex)
- Dependencies on other tasks
