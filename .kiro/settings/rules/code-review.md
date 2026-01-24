# Code Review Process

## Objective
Ensure code quality, maintainability, and security through systematic peer review before merging.

## Review Scope

### What to Review
- All code changes (features, bug fixes, refactoring)
- Configuration file changes
- Security-sensitive changes (authentication, authorization, data handling)
- Database schema changes

### What NOT to Review
- Auto-generated files (unless significantly modified)
- Dependency lockfiles (unless security-related)
- Minor documentation typos

## Review Criteria

### 1. Correctness
- Code implements the intended functionality
- Edge cases are handled
- No obvious bugs or logic errors
- Tests pass and cover new code

### 2. Security
- No hardcoded credentials or secrets
- Input validation at system boundaries
- Proper authentication and authorization checks
- No SQL injection, XSS, or other OWASP vulnerabilities

### 3. Performance
- No unnecessary database queries (N+1 problem)
- Efficient algorithms for the data size
- Proper use of caching where appropriate
- No memory leaks or resource exhaustion risks

### 4. Code Quality
- Follows project coding standards
- Clear and descriptive naming
- Appropriate comments (explain "why", not "what")
- No dead code or unused imports
- DRY principle respected

### 5. Maintainability
- Single responsibility principle
- Appropriate abstraction level
- Easy to understand and modify
- Proper error handling and logging

## Review Process

### Step 1: Self-Review
Before requesting review:
- [ ] Run all tests locally
- [ ] Check for linting errors
- [ ] Review your own diff
- [ ] Remove debug code and console.log/print statements
- [ ] Update documentation if needed

### Step 2: Request Review
- Create Pull Request with clear description
- Link related issues or requirements
- Highlight areas needing special attention
- Assign appropriate reviewers

### Step 3: Reviewer Actions
For each file changed:
```
1. Understand the context (read linked issues/requirements)
2. Check against review criteria
3. Test locally if significant changes
4. Leave constructive feedback
5. Approve, request changes, or comment
```

### Step 4: Address Feedback
- Respond to all comments
- Make requested changes or explain why not
- Re-request review after changes
- Do not merge until approved

## Feedback Guidelines

### For Reviewers
- Be respectful and constructive
- Explain the "why" behind suggestions
- Distinguish between blocking issues and suggestions
- Use prefixes:
  - `[BLOCKING]` - Must fix before merge
  - `[SUGGESTION]` - Nice to have, optional
  - `[QUESTION]` - Need clarification
  - `[NIT]` - Minor style issue

### For Authors
- Assume good intent
- Respond to all comments
- Explain your reasoning
- Be open to alternative approaches

## Merge Criteria

### Required
- [ ] All tests pass
- [ ] At least one approval from team member
- [ ] No unresolved blocking comments
- [ ] CI/CD checks pass
- [ ] No merge conflicts

### Recommended
- [ ] Documentation updated
- [ ] Changelog updated (if applicable)
- [ ] Tested in staging environment (for significant changes)

## Special Cases

### Security-Sensitive Changes
- Require review from security-aware team member
- Additional scrutiny for:
  - Authentication/authorization logic
  - Cryptographic operations
  - User data handling
  - API endpoint security

### Database Migrations
- Review for data integrity
- Check rollback strategy
- Verify backward compatibility
- Test with production-like data volume

### API Changes
- Check backward compatibility
- Verify documentation updates
- Review error responses
- Consider versioning strategy

## Turnaround Time

| Change Size | Target Review Time |
|-------------|-------------------|
| Small (< 50 lines) | Same day |
| Medium (50-200 lines) | 1 business day |
| Large (> 200 lines) | 2 business days |

Note: Complex or security-sensitive changes may require more time.
