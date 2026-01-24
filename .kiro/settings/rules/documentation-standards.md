# Documentation Standards

## Heading Conventions

### Use Noun Phrases for Headings
- Start headings with noun phrases, not verbs
- Keep headings concise and descriptive

```markdown
<!-- Good -->
## User Authentication Setup
## API Endpoint Reference
## Error Handling Strategy

<!-- Bad -->
## Setting Up User Authentication
## How to List API Endpoints
## Handling Errors
```

## Code Example Conventions

### Always Provide Explanation with Code Examples
- Include explanatory text before or after code blocks
- Explain what the code does and why it's written that way

```markdown
<!-- Good -->
To fetch user information, use the `fetchUser` function.
Pass the user ID as an argument to retrieve the corresponding user object.

\`\`\`typescript
const user = await fetchUser(userId);
\`\`\`

<!-- Bad -->
\`\`\`typescript
const user = await fetchUser(userId);
\`\`\`
```

## Image Conventions

### Always Include Alt Attributes for Images
- Add descriptive alt attributes to all images
- Required for screen reader accessibility and SEO

```markdown
<!-- Good -->
![Login screen screenshot](./images/login-screen.png)
![System architecture diagram: data flow from frontend to backend](./images/architecture.png)

<!-- Bad -->
![](./images/login-screen.png)
![image](./images/architecture.png)
```

### Images in JSX/TSX
```tsx
// Good
<img src={loginImage} alt="Login screen screenshot" />

// Bad
<img src={loginImage} />
<img src={loginImage} alt="" />
```

## Additional Guidelines

### Link Text
- Use descriptive link text, not "click here"
```markdown
<!-- Good -->
See the [API documentation](./api.md) for details.

<!-- Bad -->
[Click here](./api.md) to see the API documentation.
```

### Code References
- Use backticks for inline code references
```markdown
<!-- Good -->
Call the `fetchUser()` function with a valid `userId`.

<!-- Bad -->
Call the fetchUser() function with a valid userId.
```
