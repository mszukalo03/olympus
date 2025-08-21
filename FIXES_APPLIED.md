# Custom Endpoints Fixes Applied

## 🔧 Issues Fixed

### 1. SearXNG 403 Error Fixed
**Problem**: `AI Error: AppError(ErrorType.network: SearXNG search failed (403))`

**Root Cause**: SearXNG instances often block requests that don't look like real browsers.

**Solutions Applied**:
- ✅ Updated User-Agent to mimic a real browser
- ✅ Added proper HTTP headers (Accept-Language, Accept-Encoding, etc.)
- ✅ Improved error messages with specific 403 handling
- ✅ Added suggestions for public instances when 403 occurs
- ✅ Enhanced help text with working public instances

### 2. Jellyseerr API Key Support Added
**Problem**: `AI Error: AppError(ErrorType.unauthorized: Unauthorized - check your Jellyseerr API key)`

**Root Cause**: No way to configure API keys for Jellyseerr authentication.

**Solutions Applied**:
- ✅ Added `api_key` field to custom endpoint configuration
- ✅ Updated Settings UI with secure API key input field
- ✅ Enhanced Jellyseerr service to use API keys properly
- ✅ Improved error messages to guide users on API key setup
- ✅ Added help text explaining how to get Jellyseerr API keys

## 🚀 Enhanced Features

### SearXNG Improvements
```dart
// Before: Basic headers
headers = {'Accept': 'application/json', 'User-Agent': 'AI-Orchestrator/1.0'}

// After: Browser-like headers
headers = {
  'Accept': 'application/json',
  'Accept-Language': 'en-US,en;q=0.9',
  'Accept-Encoding': 'gzip, deflate',
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36...',
  'Cache-Control': 'no-cache',
  'Pragma': 'no-cache',
}
```

### Jellyseerr API Key Support
```dart
// Settings UI now includes:
TextField(
  controller: apiKeyCtrl,
  decoration: InputDecoration(
    labelText: 'API Key (optional)',
    hintText: 'Enter API key if required',
  ),
  obscureText: true, // Secure input
)

// Service properly uses API key:
if (apiKey != null && apiKey.trim().isNotEmpty) {
  headers['X-Api-Key'] = apiKey.trim();
}
```

## 📱 User Experience Improvements

### Better Error Messages
- **SearXNG 403**: Now suggests working public instances
- **Jellyseerr 401**: Explains how to get and configure API key
- **General failures**: More specific guidance for resolution

### Enhanced Help System
- `/j help` - Shows API key requirement and setup steps
- `/search help` - Lists working public instances
- Improved main help with configuration guidance

### Settings UI Enhancements
- Secure API key input (obscured text)
- Visual indication when API key is configured
- Better validation and error feedback

## 🔧 Technical Improvements

### Configuration System
- Extended `AppConfig` to support API keys
- Backward compatible with existing configurations
- Secure storage considerations documented

### Error Handling
- Specific handling for 403 (Forbidden) errors
- Better error message extraction from API responses
- User-friendly guidance for common issues

### Testing & Validation
- API key field validation
- Endpoint connectivity testing includes auth
- Public instance suggestions for easy setup

## 📋 Usage Examples

### Setting Up Jellyseerr
1. Go to Settings → Custom Endpoints
2. Edit the Jellyseerr endpoint
3. Add your API key in the "API Key" field
4. Test connectivity
5. Use: `/j The Matrix`

### Setting Up SearXNG
1. If default localhost fails with 403
2. Try a public instance like `https://search.sapti.me`
3. Update URL in Settings → Custom Endpoints
4. Use: `/search flutter tutorials`

## 🎯 Testing Results

### Before Fixes
```
❌ /j The Matrix → "Unauthorized - check your Jellyseerr API key"
❌ /search flutter → "SearXNG search failed (403)"
```

### After Fixes
```
✅ /j The Matrix → Returns movie results with API key configured
✅ /search flutter → Returns web search results with proper headers
✅ Enhanced error messages guide users to solutions
✅ Settings UI supports secure API key management
```

## 🔐 Security Notes

- API keys are stored in local configuration file
- Input fields use `obscureText: true` for visual security
- Keys are transmitted via HTTPS when using secure endpoints
- Consider additional encryption for production deployments

## 🚀 Ready for Production

Both issues are now resolved:
1. **SearXNG 403 errors** fixed with proper browser-like headers
2. **Jellyseerr API key support** fully implemented with secure UI

Users can now successfully use both endpoints with proper configuration guidance and error handling.
