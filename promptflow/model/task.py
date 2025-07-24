from promptflow.core import tool
import json

from azure.identity import ClientSecretCredential
from azure.core.paging import ItemPaged

from azure.mgmt.resource import ResourceManagementClient, SubscriptionClient
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.authorization import AuthorizationManagementClient
from azure.mgmt.web import WebSiteManagementClient
from azure.mgmt.loganalytics import LogAnalyticsManagementClient
from azure.mgmt.containerinstance import ContainerInstanceManagementClient
from azure.mgmt.containerservice import ContainerServiceClient
from azure.mgmt.monitor import MonitorManagementClient
from azure.mgmt.keyvault import KeyVaultManagementClient
from azure.mgmt.cognitiveservices import CognitiveServicesManagementClient
from azure.mgmt.eventgrid import EventGridManagementClient
from azure.mgmt.servicebus import ServiceBusManagementClient
from azure.mgmt.logic import LogicManagementClient
from azure.mgmt.apimanagement import ApiManagementClient
from azure.mgmt.dns import DnsManagementClient
from azure.mgmt.containerregistry import ContainerRegistryManagementClient
from azure.mgmt.msi import ManagedServiceIdentityClient
from azure.mgmt.network import NetworkManagementClient


@tool
def azure_task_handler(input1: str, tenantId: str, clientId: str, clientSecret: str, subscriptionId: str):
    try:
        while isinstance(input1, str):
            input1 = json.loads(input1)
        data = input1
    except json.JSONDecodeError:
        return {"error": "Invalid input format. Could not parse input as JSON."}

    if data.get("status") == "confirmation_succeeded" and data.get("needs_confirmation") == "done":
        operation_desc = data.get("operation", "Unknown operation")
        code_to_exec = data.get("code", "")

        # Handle multiple code snippets if code_to_exec is a list
        if isinstance(code_to_exec, list):
            all_results = []
            for snippet in code_to_exec:
                res = execute_operation(snippet, operation_desc, tenantId, clientId, clientSecret, subscriptionId)
                all_results.append(res.get("result", res))
            return {
                "status": "operation_completed",
                "operation": operation_desc,
                "results": all_results,
                "next_step": "Executed all code snippets successfully"
            }
        else:
            return execute_operation(code_to_exec, operation_desc, tenantId, clientId, clientSecret, subscriptionId)

    return data


def serialize_result(result):
    if isinstance(result, ItemPaged):
        return [serialize_result(item) for item in result]
    elif isinstance(result, dict):
        return {k: serialize_result(v) for k, v in result.items()}
    elif isinstance(result, list):
        return [serialize_result(item) for item in result]
    elif hasattr(result, "__dict__"):
        return {k: serialize_result(v) for k, v in vars(result).items() if not k.startswith("_")}
    return result


def execute_operation(code, operation_desc, tenantId, clientId, clientSecret, subscriptionId):
    try:
        credential = ClientSecretCredential(tenantId, clientId, clientSecret)

        resource_client = ResourceManagementClient(credential, subscriptionId)
        subscription_client = SubscriptionClient(credential)
        compute_client = ComputeManagementClient(credential, subscriptionId)
        storage_client = StorageManagementClient(credential, subscriptionId)
        network_client = NetworkManagementClient(credential, subscriptionId)
        authorization_client = AuthorizationManagementClient(credential, subscriptionId)
        web_client = WebSiteManagementClient(credential, subscriptionId)
        log_analytics_client = LogAnalyticsManagementClient(credential, subscriptionId)
        container_instance_client = ContainerInstanceManagementClient(credential, subscriptionId)
        container_service_client = ContainerServiceClient(credential, subscriptionId)
        monitor_client = MonitorManagementClient(credential, subscriptionId)
        keyvault_client = KeyVaultManagementClient(credential, subscriptionId)
        cognitive_client = CognitiveServicesManagementClient(credential, subscriptionId)
        eventgrid_client = EventGridManagementClient(credential, subscriptionId)
        servicebus_client = ServiceBusManagementClient(credential, subscriptionId)
        logic_client = LogicManagementClient(credential, subscriptionId)
        apimanagement_client = ApiManagementClient(credential, subscriptionId)
        dns_client = DnsManagementClient(credential, subscriptionId)
        container_registry_client = ContainerRegistryManagementClient(credential, subscriptionId)
        msi_client = ManagedServiceIdentityClient(credential, subscriptionId)

        local_scope = {
            "subscriptionId": subscriptionId,
            "resource_client": resource_client,
            "subscription_client": subscription_client,
            "compute_client": compute_client,
            "storage_client": storage_client,
            "network_client": network_client,
            "authorization_client": authorization_client,
            "web_client": web_client,
            "loganalytics_client": log_analytics_client,
            "container_client": container_instance_client,
            "aks_client": container_service_client,
            "monitor_client": monitor_client,
            "keyvault_client": keyvault_client,
            "cognitive_client": cognitive_client,
            "eventgrid_client": eventgrid_client,
            "servicebus_client": servicebus_client,
            "logic_client": logic_client,
            "apimanagement_client": apimanagement_client,
            "dns_client": dns_client,
            "container_registry_client": container_registry_client,
            "msi_client": msi_client,
        }

        exec_globals = {"__builtins__": __builtins__}
        exec(code, exec_globals, local_scope)

        result = local_scope.get("result", "No 'result' variable was defined.")
        safe_result = serialize_result(result)

        return {
            "status": "operation_completed",
            "operation": operation_desc,
            "result": safe_result,
            "next_step": "Operation executed successfully"
        }

    except Exception as e:
        return {
            "status": "execution_failed",
            "operation": operation_desc,
            "error": str(e),
            "next_step": "Error during execution"
        }
