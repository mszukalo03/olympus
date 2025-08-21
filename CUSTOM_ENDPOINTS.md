# Custom Endpoints Feature

This document describes the new custom endpoint functionality that allows routing chat messages to different APIs based on shortcut prefixes.

## Overview

The AI Orchestrator now supports routing messages to different endpoints based on a leading "/" in the prompt. This enables integration with various APIs like Jellyseerr, SearXNG, and custom services.

## Usage

### Basic Syntax
```
/[shortcut] [query]
```

### Examples
- `/j The Matrix` - Search for "The Matrix" in Jellyseerr
- `/search flutter tutorial` - Search for "flutter tutorial" in SearXNG  
- `/help` - Show help information

## Built-in Endpoints

### Jellyseerr (`/j`)
- **Purpose**: Search for movies and TV shows
- **Default URL**: `http://localhost:5055/api/v1`
- **API Key**: Required for most instances
- **Example**: `/j Breaking Bad`
- **Features**:
  - Shows availability status
  - Displays ratings and release dates
  - Truncated plot summaries
  - Limited to top 5 results for chat display

#### Getting Jellyseerr API Key
1. Log into your Jellyseerr instance
2. Go to Settings → General → API Key
3. Copy the API key
4. In AI Orchestrator: Settings → Custom Endpoints → Edit Jellyseerr → Enter API Key

### SearXNG (`/search`)
- **Purpose**: Web search
- **Default URL**: `http://localhost:8080`
- **API Key**: Not required
- **Example**: `/search AI development best practices`
- **Features**:
  - General web search
  - Category filtering (e.g., `category:news`)
  - Source attribution
  - Limited to top 5 results for chat display

#### SearXNG 403 Error Fix
If you get a 403 Forbidden error:
1. Check if your SearXNG instance allows API access
2. Try a public SearXNG instance (e.g., `https://search.sapti.me`)
3. Verify the instance is properly configured
4. Some instances block programmatic access

## Configuration

### Settings Screen
1. Navigate to Settings
2. Expand "Custom Endpoints" section
3. Add, edit, or delete endpoints
4. Configure API keys for services that require them
5. Test connectivity

### Configuration Format
Each endpoint requires:
- **Shortcut**: Single word identifier (without /)
- **Name**: Human-readable display name
- **Type**: Endpoint type (jellyseerr, searxng, custom)
- **URL**: Base URL for the API
- **API Key**: Optional authentication key

### Runtime Configuration
Custom endpoints are stored in `config_runtime.json`:

```json
{
  "custom_endpoints": {
    "j": {
      "name": "Jellyseerr",
      "url": "http://localhost:5055/api/v1",
      "type": "jellyseerr",
      "api_key": "your_jellyseerr_api_key_here"
    },
    "search": {
      "name": "SearXNG", 
      "url": "http://localhost:8080",
      "type": "searxng",
      "api_key": ""
    }
  }
}
```

## Error Troubleshooting

### Common Jellyseerr Errors
- **401 Unauthorized**: Missing or invalid API key
  - Solution: Add/verify API key in Settings
- **403 Forbidden**: Insufficient permissions
  - Solution: Check user permissions in Jellyseerr
- **404 Not Found**: Incorrect URL
  - Solution: Verify base URL points to `/api/v1`

### Common SearXNG Errors  
- **403 Forbidden**: Instance blocks API access
  - Solution: Try different public instance or enable API access
- **429 Rate Limited**: Too many requests
  - Solution: Wait and try again later
- **Connection Failed**: Instance unavailable
  - Solution: Check instance status and URL

### General Debugging
1. Use "Test" button in Settings to verify connectivity
2. Check instance logs for detailed error information
3. Verify network connectivity and firewall settings
4. Try different public instances if self-hosted ones fail

## Public Instance Examples

### Working SearXNG Instances
- `https://search.sapti.me`
- `https://searx.be`
- `https://search.bus-hit.me`
- `https://searx.tiekoetter.com`

### Jellyseerr Setup
- Must be self-hosted or have API access
- Default local URL: `http://localhost:5055/api/v1`
- API key required for authentication

## API Requirements

### Jellyseerr
- API endpoint: `/search`
- Required: X-Api-Key header
- Response format: Standard Jellyseerr search response
- Authentication: API key from instance settings

### SearXNG
- API endpoint: `/search`
- Parameters: `q`, `format=json`, `safesearch`
- Response format: Standard SearXNG JSON response
- Authentication: None (but instance may block programmatic access)

## Security Considerations

- API keys stored in plain text in local config file
- Consider the security implications of storing API keys
- Network requests made over HTTP/HTTPS as configured
- No input sanitization beyond basic validation
- Consider rate limiting for external APIs

## Future Enhancements

- Encrypted credential storage
- OAuth/token-based authentication
- Instance health monitoring
- Automatic failover between instances
- Enhanced error recovery and retry logic
