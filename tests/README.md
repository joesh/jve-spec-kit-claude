# JVE Editor Test Suite

## Testing Strategy
Following constitutional Test-First Development (TDD), all tests are written before implementation.

## Test Categories

### Contract Tests (`tests/contract/`)
Test API contracts defined in OpenAPI specifications. These ensure command system reliability and deterministic behavior.
- **Purpose**: Validate API compliance
- **Run before**: Any implementation
- **Must fail initially**: Yes (TDD requirement)

### Integration Tests (`tests/integration/`)  
Test complete workflows from quickstart.md scenarios. These validate end-to-end functionality.
- **Purpose**: Validate user workflows
- **Dependencies**: Requires UI components
- **Execution**: Full application context

### Unit Tests (`tests/unit/`)
Test individual components in isolation with mocked dependencies.
- **Purpose**: Component validation  
- **Scope**: Single classes/functions
- **Dependencies**: Minimal (mocked)

### Lua Tests (`tests/lua/`)
Test script runtime and Lua-to-C++ integration.
- **Purpose**: Scripting system validation
- **Dependencies**: LuaJIT runtime
- **Coverage**: API bindings, script behaviors

## Running Tests

### All Tests
```bash
cd build
ctest --output-on-failure
```

### Specific Category
```bash
# Contract tests only
ctest -R "test_.*_contract" --output-on-failure

# Integration tests only  
ctest -R "test_.*_workflow" --output-on-failure

# Unit tests only
ctest -R "test_.*_unit" --output-on-failure
```

### Individual Test
```bash
./test_command_execute
```

## Test Naming Convention
- Contract tests: `test_[api]_[operation].cpp` → `test_command_execute`
- Integration tests: `test_[workflow]_workflow.cpp` → `test_project_workflow`
- Unit tests: `test_[component]_unit.cpp` → `test_project_unit`

## Constitutional Compliance
- ✅ **Test-First**: All tests written before implementation
- ✅ **85% Coverage**: Required minimum with meaningful tests
- ✅ **Red-Green-Refactor**: Strict TDD cycle enforcement
- ✅ **Contract Validation**: API compliance verified
- ✅ **Deterministic**: Command system produces identical results

## CI Pipeline Requirements
1. **Build**: Clean build from source
2. **Test**: All categories pass
3. **Coverage**: Minimum 85% line coverage
4. **Lint**: Code style compliance  
5. **Performance**: Rendering benchmarks meet targets