# Custom Endpoints Troubleshooting Guide

## 🔧 Common Issues & Solutions

### SearXNG 403 Forbidden Errors

#### Problem
```
AI Error: AppError(ErrorType.forbidden: SearXNG access forbidden)
```

#### Root Causes & Solutions

1. **Instance blocks API access**
   - **Solution**: The app now automatically tries multiple public instances
   - **Manual fix**: Update URL in Settings → Custom Endpoints to a working instance

2. **Working Public Instances** (Updated 2024)
   ```
   https://searx.be
   https://search.sapti.me
   https://searx.tiekoetter.com
   https://paulgo.io
   https://search.mdosch.de
   ```

3. **Automatic Fallback**
   - If your configured instance fails, the app automatically tries public instances
   - No manual intervention needed
   - Check logs to see which instance was used

#### How to Fix
1. Try these working instances in Settings → Custom Endpoints:
   - Replace URL with `https://searx.be` or `https://search.sapti.me`
2. Test the connection using the "Test" button
3. The app will automatically fall back to working instances

### Jellyseerr Authorization Errors

#### Problem
```
AI Error: AppError(ErrorType.unauthorized: Unauthorized - check your Jellyseerr API key)
AI Error: AppError(ErrorType.network: Jellyseerr error: Parameter 'query' must be url encoded)
```

#### Solutions

1. **Get Your API Key**
   ```
   1. Login to Jellyseerr web interface
   2. Go to Settings → General
   3. Find "API Key" section
   4. Copy the long key (starts with alphanumeric characters)
   ```

2. **Configure in App**
   ```
   1. Open AI Orchestrator Settings
   2. Expand "Custom Endpoints"
   3. Edit Jellyseerr endpoint
   4. Paste API key in "API Key" field (will be hidden with ****)
   5. Test connection
   ```

3. **URL Format**
   - Correct: `http://localhost:5055/api/v1`
   - Correct: `https://jellyseerr.yourdomain.com/api/v1`
   - Wrong: `http://localhost:5055` (missing /api/v1)

## 🚀 Enhanced Features (Latest Fixes)

### SearXNG Improvements
- **Auto-fallback**: Tries multiple instances automatically
- **Better headers**: Mimics real browser to avoid blocking
- **Improved error messages**: Suggests working alternatives
- **Public instance rotation**: Uses multiple known-working instances

### Jellyseerr Improvements  
- **Proper URL encoding**: Fixes query parameter issues
- **API key validation**: Clear error messages about missing/invalid keys
- **Better authentication**: Proper header handling
- **Connection testing**: Tests with API key authentication

## 📱 Step-by-Step Setup

### Setting Up SearXNG
1. **Option A: Use defaults** (app will auto-fallback to working instances)
2. **Option B: Configure manually**:
   ```
   Settings → Custom Endpoints → Edit SearXNG
   URL: https://searx.be
   Test Connection → Should show "✓ SearXNG connection successful"
   ```

### Setting Up Jellyseerr
1. **Get API Key from Jellyseerr**:
   ```
   Login → Settings → General → API Key → Copy
   ```
2. **Configure in App**:
   ```
   Settings → Custom Endpoints → Edit Jellyseerr
   URL: http://your-jellyseerr:5055/api/v1
   API Key: [paste your key here]
   Test Connection → Should show "✓ Jellyseerr connection successful"
   ```

## 🧪 Testing Your Setup

### Test Commands
```bash
# Test SearXNG
/search test query

# Test Jellyseerr  
/j The Matrix
```

### Expected Results
```
✅ SearXNG: Returns web search results
✅ Jellyseerr: Returns movie/TV show with availability status
```

### Connection Test Results
- **✓ Connection successful**: Ready to use
- **⚠️ Reachable but blocked**: Try different instance/check API key
- **❌ Test failed**: Check URL/network connectivity

## 🔍 Debugging Steps

### Enable Logging
1. Check app logs for detailed error messages
2. Look for "Trying SearXNG instance X/Y" messages
3. Note which instances succeed/fail

### SearXNG Debug
```
1. Try URL directly in browser: https://searx.be/search?q=test&format=json
2. Should return JSON response
3. If browser works but app doesn't, try different instance
```

### Jellyseerr Debug
```
1. Verify API key: GET https://your-jellyseerr/api/v1/status
2. Should return server status
3. Test search: GET https://your-jellyseerr/api/v1/search?query=test
```

## 🛠️ Advanced Configuration

### Custom SearXNG Instance
If running your own SearXNG:
```yaml
# In searxng/settings.yml
server:
  limiter: false  # Disable rate limiting
  
search:
  formats:
    - json  # Enable JSON API
```

### Jellyseerr Permissions
Make sure your Jellyseerr user has:
- Access to search functionality
- API permissions enabled
- Proper authentication setup

## 📋 Quick Reference

### Default Working URLs
```
SearXNG: https://searx.be
Jellyseerr: http://localhost:5055/api/v1 (+ API key required)
```

### Error Message Meanings
| Error | Meaning | Fix |
|-------|---------|-----|
| 403 Forbidden | Instance blocks access | Try different instance |
| 401 Unauthorized | Missing/invalid API key | Add/verify API key |
| 404 Not Found | Wrong URL | Check endpoint URL |
| 429 Rate Limited | Too many requests | Wait and retry |

### Fallback Behavior
1. **SearXNG**: Auto-tries public instances if configured one fails
2. **Jellyseerr**: Shows specific error messages for API key issues
3. **All services**: Graceful error handling with helpful messages

The latest fixes ensure both services work reliably with automatic fallbacks and better error handling!
