# Frontend Coding Standards

## Component Conventions

### Functional Components Only
- All components MUST be written as **Functional Components**
- Class Components are NOT allowed

```tsx
// Good
const UserCard: React.FC<UserCardProps> = ({ name, email }) => {
  return (
    <div>
      <h2>{name}</h2>
      <p>{email}</p>
    </div>
  );
};

// Bad
class UserCard extends React.Component<UserCardProps> {
  render() {
    return <div>...</div>;
  }
}
```

## Naming Conventions

### Functions: camelCase
```typescript
// Good
const fetchUserData = async () => { ... };
const handleClick = () => { ... };
const formatDate = (date: Date) => { ... };

// Bad
const FetchUserData = async () => { ... };
const handle_click = () => { ... };
```

### Components: PascalCase
```typescript
// Good
const UserProfile: React.FC = () => { ... };
const NavigationBar: React.FC = () => { ... };

// Bad
const userProfile: React.FC = () => { ... };
const navigation_bar: React.FC = () => { ... };
```

## Prohibited Patterns

### 1. Minimize `any` Type Usage
- Prefer explicit type definitions
- Consider using `unknown` when type is truly unknown
- Use generics with constraints when possible

```typescript
// Good
interface User {
  id: string;
  name: string;
}
const getUser = (id: string): User => { ... };

// Acceptable (when interfacing with untyped external APIs)
const getUser = (id: string): unknown => { ... };

// Bad
const getUser = (id: any): any => { ... };
```

### 2. No `console.log` in Production Code
- Remove all debug `console.log` statements before commit
- Use dedicated logging service for production logs

```typescript
// Good
logger.info('User logged in', { userId });

// Bad
console.log('User logged in', userId);
```

### 3. Never Delete Existing Tests
- Tests may be modified, but not deleted
- If a test becomes irrelevant, skip it with `.skip` and add explanation
- Skipped tests should be tracked and reviewed periodically

```typescript
// Good - Modify test to match new behavior
it('should return user data', () => {
  // Updated test implementation
});

// Good - Temporarily skip with explanation
it.skip('should return user data', () => {
  // TODO: Re-enable after API migration
});

// Bad - Deleting tests
// (deleted test)
```
