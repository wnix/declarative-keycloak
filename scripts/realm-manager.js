#!/usr/bin/env node

/**
 * Keycloak Realm Manager
 * 
 * A tool for declarative Keycloak realm management.
 * Supports creating realms only if they don't exist, and manually replacing existing realms.
 * 
 * Usage:
 *   realm-manager <action> <realm-name> <realm-file>
 * 
 * Actions:
 *   check   - Check if a realm exists
 *   create  - Create realm only if it doesn't exist
 *   replace - Delete and recreate realm (for manual replacement)
 * 
 * Environment Variables:
 *   KEYCLOAK_URL          - Keycloak base URL (required)
 *   KEYCLOAK_ADMIN_USER   - Admin username (required)
 *   KEYCLOAK_ADMIN_PASSWORD - Admin password (required)
 */

const KcAdminClient = require('@keycloak/keycloak-admin-client').default;
const fs = require('fs').promises;

// Exit codes
const EXIT_SUCCESS = 0;
const EXIT_ERROR = 1;
const EXIT_REALM_EXISTS = 2;

// Configuration from environment variables
const config = {
  baseUrl: process.env.KEYCLOAK_URL || 'http://localhost:8080',
  adminUser: process.env.KEYCLOAK_ADMIN_USER || 'admin',
  adminPassword: process.env.KEYCLOAK_ADMIN_PASSWORD,
};

/**
 * Sleep for specified milliseconds
 */
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Initialize and authenticate the Keycloak admin client
 * @returns {Promise<KcAdminClient>} Authenticated admin client
 */
async function connectToKeycloak() {
  const kcAdminClient = new KcAdminClient({
    baseUrl: config.baseUrl,
    realmName: 'master',
  });

  console.log(`Connecting to Keycloak at ${config.baseUrl}...`);

  try {
    await kcAdminClient.auth({
      username: config.adminUser,
      password: config.adminPassword,
      grantType: 'password',
      clientId: 'admin-cli',
    });

    console.log('Successfully authenticated with Keycloak admin API');
    return kcAdminClient;
  } catch (error) {
    console.error('Failed to authenticate with Keycloak:', error.message);
    throw error;
  }
}

/**
 * Wait for Keycloak to be ready by checking health endpoint
 * Retries for up to 60 seconds with exponential backoff
 * @returns {Promise<void>}
 */
async function waitForKeycloak() {
  const maxAttempts = 12; // 12 attempts with exponential backoff = ~60 seconds
  let attempt = 0;

  console.log('Waiting for Keycloak to be ready...');

  while (attempt < maxAttempts) {
    try {
      // Try to create a client instance and authenticate
      const testClient = new KcAdminClient({
        baseUrl: config.baseUrl,
        realmName: 'master',
      });

      await testClient.auth({
        username: config.adminUser,
        password: config.adminPassword,
        grantType: 'password',
        clientId: 'admin-cli',
      });

      console.log('Keycloak is ready!');
      return;
    } catch (error) {
      attempt++;
      const waitTime = Math.min(1000 * Math.pow(1.5, attempt), 10000);
      
      if (attempt < maxAttempts) {
        console.log(`Keycloak not ready yet (attempt ${attempt}/${maxAttempts}), retrying in ${waitTime}ms...`);
        await sleep(waitTime);
      } else {
        console.error('Keycloak did not become ready in time');
        throw new Error('Timeout waiting for Keycloak to be ready');
      }
    }
  }
}

/**
 * Check if a realm exists
 * @param {KcAdminClient} client - Authenticated admin client
 * @param {string} realmName - Name of the realm to check
 * @returns {Promise<boolean>} True if realm exists, false otherwise
 */
async function realmExists(client, realmName) {
  try {
    const realm = await client.realms.findOne({ realm: realmName });
    // findOne returns null/undefined for non-existent realms
    return realm != null;
  } catch (error) {
    if (error.response && error.response.status === 404) {
      return false;
    }
    // For other errors, rethrow
    throw error;
  }
}

/**
 * Read and parse realm JSON file
 * @param {string} realmFile - Path to realm JSON file
 * @returns {Promise<object>} Parsed realm data
 */
async function readRealmFile(realmFile) {
  try {
    console.log(`Reading realm file: ${realmFile}`);
    const content = await fs.readFile(realmFile, 'utf-8');
    const realmData = JSON.parse(content);
    
    if (!realmData.realm) {
      throw new Error('Realm JSON must contain a "realm" field with the realm name');
    }
    
    console.log(`Loaded realm configuration for: ${realmData.realm}`);
    return realmData;
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.error(`Realm file not found: ${realmFile}`);
    } else if (error instanceof SyntaxError) {
      console.error(`Invalid JSON in realm file: ${error.message}`);
    } else {
      console.error(`Error reading realm file: ${error.message}`);
    }
    throw error;
  }
}

/**
 * Create a new realm
 * @param {KcAdminClient} client - Authenticated admin client
 * @param {object} realmData - Realm configuration data
 * @returns {Promise<void>}
 */
async function createRealm(client, realmData) {
  const realmName = realmData.realm;
  
  console.log(`Creating realm: ${realmName}`);
  
  try {
    await client.realms.create(realmData);
    console.log(`✓ Successfully created realm: ${realmName}`);
  } catch (error) {
    console.error(`✗ Failed to create realm ${realmName}:`, error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    throw error;
  }
}

/**
 * Delete a realm
 * @param {KcAdminClient} client - Authenticated admin client
 * @param {string} realmName - Name of the realm to delete
 * @returns {Promise<void>}
 */
async function deleteRealm(client, realmName) {
  console.log(`Deleting realm: ${realmName}`);
  
  try {
    await client.realms.del({ realm: realmName });
    console.log(`✓ Successfully deleted realm: ${realmName}`);
  } catch (error) {
    console.error(`✗ Failed to delete realm ${realmName}:`, error.message);
    throw error;
  }
}

/**
 * Replace an existing realm (delete and recreate)
 * @param {KcAdminClient} client - Authenticated admin client
 * @param {string} realmName - Name of the realm to replace
 * @param {object} realmData - New realm configuration data
 * @returns {Promise<void>}
 */
async function replaceRealm(client, realmName, realmData) {
  console.log(`Replacing realm: ${realmName}`);
  
  // Check if realm exists
  const exists = await realmExists(client, realmName);
  
  if (!exists) {
    console.error(`✗ Cannot replace realm ${realmName}: realm does not exist`);
    throw new Error(`Realm ${realmName} does not exist`);
  }
  
  // Delete existing realm
  await deleteRealm(client, realmName);
  
  // Wait a bit for deletion to complete
  await sleep(2000);
  
  // Create new realm
  await createRealm(client, realmData);
  
  console.log(`✓ Successfully replaced realm: ${realmName}`);
}

/**
 * Handle the 'check' action
 */
async function handleCheck(client, realmName) {
  console.log(`Checking if realm exists: ${realmName}`);
  
  const exists = await realmExists(client, realmName);
  
  if (exists) {
    console.log(`✓ Realm ${realmName} exists`);
    return EXIT_SUCCESS;
  } else {
    console.log(`✗ Realm ${realmName} does not exist`);
    return EXIT_ERROR;
  }
}

/**
 * Handle the 'create' action (idempotent - only creates if doesn't exist)
 */
async function handleCreate(client, realmName, realmFile) {
  console.log(`Creating realm ${realmName} (if it doesn't exist)`);
  
  // Check if realm already exists
  const exists = await realmExists(client, realmName);
  
  if (exists) {
    console.log(`Realm ${realmName} already exists, skipping creation`);
    return EXIT_REALM_EXISTS;
  }
  
  // Read realm configuration
  const realmData = await readRealmFile(realmFile);
  
  // Verify realm name matches
  if (realmData.realm !== realmName) {
    console.warn(`Warning: Realm name in file (${realmData.realm}) doesn't match specified name (${realmName})`);
    console.log(`Using realm name from file: ${realmData.realm}`);
  }
  
  // Create the realm
  await createRealm(client, realmData);
  
  return EXIT_SUCCESS;
}

/**
 * Handle the 'replace' action (manual realm replacement)
 */
async function handleReplace(client, realmName, realmFile) {
  console.log(`Replacing realm ${realmName}`);
  
  // Read realm configuration
  const realmData = await readRealmFile(realmFile);
  
  // Verify realm name matches
  if (realmData.realm !== realmName) {
    console.warn(`Warning: Realm name in file (${realmData.realm}) doesn't match specified name (${realmName})`);
    console.log(`Using realm name from file: ${realmData.realm}`);
  }
  
  // Replace the realm
  await replaceRealm(client, realmName, realmData);
  
  return EXIT_SUCCESS;
}

/**
 * Main entry point
 */
async function main() {
  // Parse command line arguments
  const args = process.argv.slice(2);
  
  if (args.length < 1) {
    console.error('Usage: realm-manager <action> <realm-name> <realm-file>');
    console.error('Actions: check, create, replace');
    process.exit(EXIT_ERROR);
  }
  
  const action = args[0];
  const realmName = args[1];
  const realmFile = args[2];
  
  // Validate required parameters based on action
  if (action === 'check' && !realmName) {
    console.error('Error: realm-name is required for check action');
    process.exit(EXIT_ERROR);
  }
  
  if ((action === 'create' || action === 'replace') && (!realmName || !realmFile)) {
    console.error('Error: realm-name and realm-file are required for create/replace actions');
    process.exit(EXIT_ERROR);
  }
  
  // Validate configuration
  if (!config.adminPassword) {
    console.error('Error: KEYCLOAK_ADMIN_PASSWORD environment variable is required');
    process.exit(EXIT_ERROR);
  }
  
  try {
    // Wait for Keycloak to be ready
    await waitForKeycloak();
    
    // Connect to Keycloak
    const client = await connectToKeycloak();
    
    // Execute the requested action
    let exitCode;
    
    switch (action) {
      case 'check':
        exitCode = await handleCheck(client, realmName);
        break;
        
      case 'create':
        exitCode = await handleCreate(client, realmName, realmFile);
        break;
        
      case 'replace':
        exitCode = await handleReplace(client, realmName, realmFile);
        break;
        
      default:
        console.error(`Unknown action: ${action}`);
        console.error('Valid actions: check, create, replace');
        exitCode = EXIT_ERROR;
    }
    
    process.exit(exitCode);
    
  } catch (error) {
    console.error('Fatal error:', error.message);
    if (error.stack) {
      console.error(error.stack);
    }
    process.exit(EXIT_ERROR);
  }
}

// Run main function
main();

