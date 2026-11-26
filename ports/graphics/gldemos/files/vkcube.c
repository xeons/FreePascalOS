/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * vkcube: a turning cube with coloured corners in a window of the
 * display server, drawn with Vulkan (Mesa's lavapipe) and presented
 * through the VK_FPOS_window_surface extension and a swapchain. There is
 * no Vulkan loader on the system yet, so the program opens the driver
 * (libvulkan_lvp.so) itself and takes every function from its
 * vk_icdGetInstanceProcAddr. Escape or the close button end it; resizing
 * the window makes a new swapchain. "vkcube -n FRAMES" presents that many
 * frames, checks the window shows the cube, prints the rate and ends
 * (status 0 if it did).
 */
#define VK_USE_PLATFORM_FREEPASCALOS_FPOS
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <freepascalos/windowing.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cube.vert.h"
#include "cube.frag.h"

#define WINDOW_SIDE 300 /* logical units */
#define MAXIMUM_IMAGES 8
#define CLEAR_RED 0.10f
#define CLEAR_GREEN 0.12f
#define CLEAR_BLUE 0.20f

/* --- The functions, from the driver ---------------------------------------- */

static PFN_vkGetInstanceProcAddr get_instance_proc_address;
/* The driver interface's first call (vk_icd.h, which is not installed). */
typedef VkResult(VKAPI_PTR *negotiate_function)(uint32_t *version);

#define INSTANCE_FUNCTIONS(X) \
	X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) \
	X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) \
	X(vkCreateDevice) X(vkGetDeviceProcAddr) X(vkCreateWindowSurfaceFPOS) X(vkDestroySurfaceKHR) \
	X(vkGetPhysicalDeviceSurfaceSupportKHR) X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) \
	X(vkGetPhysicalDeviceSurfaceFormatsKHR)

#define DEVICE_FUNCTIONS(X) \
	X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) X(vkCreateSwapchainKHR) \
	X(vkDestroySwapchainKHR) X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) X(vkQueuePresentKHR) \
	X(vkCreateImageView) X(vkDestroyImageView) X(vkCreateImage) X(vkDestroyImage) \
	X(vkGetImageMemoryRequirements) X(vkBindImageMemory) X(vkCreateBuffer) X(vkDestroyBuffer) \
	X(vkGetBufferMemoryRequirements) X(vkBindBufferMemory) X(vkAllocateMemory) X(vkFreeMemory) \
	X(vkMapMemory) X(vkUnmapMemory) X(vkCreateRenderPass) X(vkDestroyRenderPass) \
	X(vkCreateFramebuffer) X(vkDestroyFramebuffer) X(vkCreateShaderModule) X(vkDestroyShaderModule) \
	X(vkCreatePipelineLayout) X(vkDestroyPipelineLayout) X(vkCreateGraphicsPipelines) \
	X(vkDestroyPipeline) X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
	X(vkResetCommandBuffer) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCmdBeginRenderPass) \
	X(vkCmdEndRenderPass) X(vkCmdBindPipeline) X(vkCmdBindVertexBuffers) X(vkCmdPushConstants) \
	X(vkCmdSetViewport) X(vkCmdSetScissor) X(vkCmdDraw) X(vkQueueSubmit) X(vkCreateSemaphore) \
	X(vkDestroySemaphore) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences)

#define DECLARE(name) static PFN_##name name;
INSTANCE_FUNCTIONS(DECLARE)
DEVICE_FUNCTIONS(DECLARE)

static int load_driver(void)
{
	negotiate_function negotiate;
	uint32_t interface_version = 5;
	void *driver = dlopen("libvulkan_lvp.so", RTLD_NOW | RTLD_LOCAL);
	if (!driver) {
		fprintf(stderr, "vkcube: cannot open libvulkan_lvp.so: %s\n", dlerror());
		return 0;
	}
	negotiate = (negotiate_function)dlsym(driver, "vk_icdNegotiateLoaderICDInterfaceVersion");
	if (negotiate)
		negotiate(&interface_version);
	get_instance_proc_address = (PFN_vkGetInstanceProcAddr)dlsym(driver, "vk_icdGetInstanceProcAddr");
	return get_instance_proc_address != NULL;
}

static int load_instance_functions(VkInstance instance)
{
	int complete = 1;
#define LOAD_INSTANCE(name) \
	name = (PFN_##name)get_instance_proc_address(instance, #name); \
	if (!name) { fprintf(stderr, "vkcube: no %s\n", #name); complete = 0; }
	INSTANCE_FUNCTIONS(LOAD_INSTANCE)
	return complete;
}

static int load_device_functions(VkDevice device)
{
	int complete = 1;
#define LOAD_DEVICE(name) \
	name = (PFN_##name)vkGetDeviceProcAddr(device, #name); \
	if (!name) { fprintf(stderr, "vkcube: no %s\n", #name); complete = 0; }
	DEVICE_FUNCTIONS(LOAD_DEVICE)
	return complete;
}

/* --- The state --------------------------------------------------------------- */

struct swapchain_state {
	VkSwapchainKHR swapchain;
	VkExtent2D extent;
	uint32_t image_count;
	VkImage images[MAXIMUM_IMAGES];
	VkImageView views[MAXIMUM_IMAGES];
	VkFramebuffer framebuffers[MAXIMUM_IMAGES];
	VkImage depth_image;
	VkDeviceMemory depth_memory;
	VkImageView depth_view;
};

static VkInstance instance;
static VkPhysicalDevice physical_device;
static VkDevice device;
static VkQueue queue;
static uint32_t queue_family;
static VkSurfaceKHR surface;
static VkFormat color_format;
static VkRenderPass render_pass;
static VkPipelineLayout pipeline_layout;
static VkPipeline pipeline;
static VkBuffer vertex_buffer;
static VkDeviceMemory vertex_memory;
static VkCommandPool command_pool;
static VkCommandBuffer command_buffer;
static VkSemaphore image_acquired;
static VkSemaphore rendering_done;
static VkFence frame_done;
static struct swapchain_state chain;

static int check(VkResult result, const char *what)
{
	if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
		fprintf(stderr, "vkcube: %s failed (%d)\n", what, result);
		return 0;
	}
	return 1;
}

static double seconds_now(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return now.tv_sec + now.tv_nsec / 1e9;
}

/* --- Matrices (column major; Vulkan's clip space: y down, depth 0 to 1) --- */

static void multiply(float result[16], const float a[16], const float b[16])
{
	float out[16];
	for (int column = 0; column < 4; column++)
		for (int row = 0; row < 4; row++) {
			float sum = 0;
			for (int k = 0; k < 4; k++)
				sum += a[k * 4 + row] * b[column * 4 + k];
			out[column * 4 + row] = sum;
		}
	memcpy(result, out, sizeof(out));
}

static void cube_transform(float result[16], float seconds, float aspect)
{
	const float near = 0.1f, far = 100.0f, focal = 1.0f / tanf(0.5f * 45.0f * (float)M_PI / 180.0f);
	float projection[16] = {0}, view[16] = {0}, spin_y[16] = {0}, spin_x[16] = {0};
	float angle_y = seconds * 1.1f, angle_x = seconds * 0.7f;

	projection[0] = focal / aspect;
	projection[5] = -focal;
	projection[10] = far / (near - far);
	projection[11] = -1.0f;
	projection[14] = near * far / (near - far);

	view[0] = view[5] = view[10] = view[15] = 1.0f;
	view[14] = -5.0f;

	spin_y[0] = cosf(angle_y);
	spin_y[2] = -sinf(angle_y);
	spin_y[5] = 1.0f;
	spin_y[8] = sinf(angle_y);
	spin_y[10] = cosf(angle_y);
	spin_y[15] = 1.0f;

	spin_x[0] = 1.0f;
	spin_x[5] = cosf(angle_x);
	spin_x[6] = sinf(angle_x);
	spin_x[9] = -sinf(angle_x);
	spin_x[10] = cosf(angle_x);
	spin_x[15] = 1.0f;

	multiply(result, spin_y, spin_x);
	multiply(result, view, result);
	multiply(result, projection, result);
}

/* --- Set up ------------------------------------------------------------------ */

static uint32_t memory_type(uint32_t allowed, VkMemoryPropertyFlags wanted)
{
	VkPhysicalDeviceMemoryProperties properties;
	vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
	for (uint32_t i = 0; i < properties.memoryTypeCount; i++)
		if ((allowed & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted)
			return i;
	return 0;
}

static int create_instance_and_surface(struct fpos_window *window)
{
	const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_FPOS_WINDOW_SURFACE_EXTENSION_NAME};
	VkApplicationInfo application = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "vkcube",
		.apiVersion = VK_API_VERSION_1_1,
	};
	VkInstanceCreateInfo instance_info = {
		.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &application,
		.enabledExtensionCount = 2,
		.ppEnabledExtensionNames = extensions,
	};
	VkWindowSurfaceCreateInfoFPOS surface_info = {
		.sType = VK_STRUCTURE_TYPE_WINDOW_SURFACE_CREATE_INFO_FPOS,
		.window = window,
	};
	PFN_vkCreateInstance create_instance =
		(PFN_vkCreateInstance)get_instance_proc_address(NULL, "vkCreateInstance");

	if (!create_instance || !check(create_instance(&instance_info, NULL, &instance), "vkCreateInstance"))
		return 0;
	if (!load_instance_functions(instance))
		return 0;
	return check(vkCreateWindowSurfaceFPOS(instance, &surface_info, NULL, &surface), "vkCreateWindowSurfaceFPOS");
}

static int create_device(void)
{
	VkPhysicalDevice devices[4];
	uint32_t device_count = 4, family_count = 0;
	VkQueueFamilyProperties families[16];
	VkPhysicalDeviceProperties properties;
	const float priority = 1.0f;
	const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
	VkDeviceQueueCreateInfo queue_info = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueCount = 1,
		.pQueuePriorities = &priority,
	};
	VkDeviceCreateInfo device_info = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &queue_info,
		.enabledExtensionCount = 1,
		.ppEnabledExtensionNames = extensions,
	};

	if (!check(vkEnumeratePhysicalDevices(instance, &device_count, devices), "vkEnumeratePhysicalDevices") ||
	    device_count == 0)
		return 0;
	physical_device = devices[0];
	vkGetPhysicalDeviceProperties(physical_device, &properties);
	printf("vkcube: %s, Vulkan %u.%u.%u\n", properties.deviceName, VK_API_VERSION_MAJOR(properties.apiVersion),
	       VK_API_VERSION_MINOR(properties.apiVersion), VK_API_VERSION_PATCH(properties.apiVersion));

	family_count = 16;
	vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families);
	queue_family = UINT32_MAX;
	for (uint32_t i = 0; i < family_count; i++) {
		VkBool32 presents = VK_FALSE;
		vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, i, surface, &presents);
		if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && presents) {
			queue_family = i;
			break;
		}
	}
	if (queue_family == UINT32_MAX) {
		fprintf(stderr, "vkcube: no queue draws and presents\n");
		return 0;
	}
	queue_info.queueFamilyIndex = queue_family;
	if (!check(vkCreateDevice(physical_device, &device_info, NULL, &device), "vkCreateDevice"))
		return 0;
	if (!load_device_functions(device))
		return 0;
	vkGetDeviceQueue(device, queue_family, 0, &queue);
	return 1;
}

static int choose_format(void)
{
	VkSurfaceFormatKHR formats[16];
	uint32_t count = 16;
	if (!check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, formats),
		   "vkGetPhysicalDeviceSurfaceFormatsKHR") || count == 0)
		return 0;
	color_format = formats[0].format;
	for (uint32_t i = 0; i < count; i++)
		if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM)
			color_format = formats[i].format;
	return 1;
}

static int create_render_pass(void)
{
	VkAttachmentDescription attachments[2] = {
		{
			.format = color_format,
			.samples = VK_SAMPLE_COUNT_1_BIT,
			.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE,
			.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
			.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
			.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
		},
		{
			.format = VK_FORMAT_D32_SFLOAT,
			.samples = VK_SAMPLE_COUNT_1_BIT,
			.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
			.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
			.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
			.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		},
	};
	VkAttachmentReference color_reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
	VkAttachmentReference depth_reference = {1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
	VkSubpassDescription subpass = {
		.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1,
		.pColorAttachments = &color_reference,
		.pDepthStencilAttachment = &depth_reference,
	};
	VkSubpassDependency dependency = {
		.srcSubpass = VK_SUBPASS_EXTERNAL,
		.dstSubpass = 0,
		.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
	};
	VkRenderPassCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = 2,
		.pAttachments = attachments,
		.subpassCount = 1,
		.pSubpasses = &subpass,
		.dependencyCount = 1,
		.pDependencies = &dependency,
	};
	return check(vkCreateRenderPass(device, &info, NULL, &render_pass), "vkCreateRenderPass");
}

static VkShaderModule shader_module(const uint32_t *code, size_t size)
{
	VkShaderModuleCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = size,
		.pCode = code,
	};
	VkShaderModule module = VK_NULL_HANDLE;
	check(vkCreateShaderModule(device, &info, NULL, &module), "vkCreateShaderModule");
	return module;
}

static int create_pipeline(void)
{
	VkShaderModule vertex = shader_module(cube_vertex_shader, sizeof(cube_vertex_shader));
	VkShaderModule fragment = shader_module(cube_fragment_shader, sizeof(cube_fragment_shader));
	VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT, 0, 16 * sizeof(float)};
	VkPipelineLayoutCreateInfo layout_info = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.pushConstantRangeCount = 1,
		.pPushConstantRanges = &push,
	};
	VkPipelineShaderStageCreateInfo stages[2] = {
		{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		 .module = vertex, .pName = "main"},
		{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		 .module = fragment, .pName = "main"},
	};
	VkVertexInputBindingDescription binding = {0, 6 * sizeof(float), VK_VERTEX_INPUT_RATE_VERTEX};
	VkVertexInputAttributeDescription attributes[2] = {
		{0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0},
		{1, 0, VK_FORMAT_R32G32B32_SFLOAT, 3 * sizeof(float)},
	};
	VkPipelineVertexInputStateCreateInfo vertex_input = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		.vertexBindingDescriptionCount = 1,
		.pVertexBindingDescriptions = &binding,
		.vertexAttributeDescriptionCount = 2,
		.pVertexAttributeDescriptions = attributes,
	};
	VkPipelineInputAssemblyStateCreateInfo assembly = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	};
	VkPipelineViewportStateCreateInfo viewport = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1,
		.scissorCount = 1,
	};
	VkPipelineRasterizationStateCreateInfo rasterization = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL,
		.cullMode = VK_CULL_MODE_NONE,
		.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
		.lineWidth = 1.0f,
	};
	VkPipelineMultisampleStateCreateInfo multisample = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
	};
	VkPipelineDepthStencilStateCreateInfo depth = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		.depthTestEnable = VK_TRUE,
		.depthWriteEnable = VK_TRUE,
		.depthCompareOp = VK_COMPARE_OP_LESS,
	};
	VkPipelineColorBlendAttachmentState blend_attachment = {
		.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
				  VK_COLOR_COMPONENT_A_BIT,
	};
	VkPipelineColorBlendStateCreateInfo blend = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1,
		.pAttachments = &blend_attachment,
	};
	VkDynamicState dynamic_states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
	VkPipelineDynamicStateCreateInfo dynamic = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		.dynamicStateCount = 2,
		.pDynamicStates = dynamic_states,
	};
	VkGraphicsPipelineCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2,
		.pStages = stages,
		.pVertexInputState = &vertex_input,
		.pInputAssemblyState = &assembly,
		.pViewportState = &viewport,
		.pRasterizationState = &rasterization,
		.pMultisampleState = &multisample,
		.pDepthStencilState = &depth,
		.pColorBlendState = &blend,
		.pDynamicState = &dynamic,
		.renderPass = render_pass,
		.subpass = 0,
	};
	int created;

	if (!check(vkCreatePipelineLayout(device, &layout_info, NULL, &pipeline_layout), "vkCreatePipelineLayout"))
		return 0;
	info.layout = pipeline_layout;
	created = check(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, NULL, &pipeline),
			"vkCreateGraphicsPipelines");
	vkDestroyShaderModule(device, vertex, NULL);
	vkDestroyShaderModule(device, fragment, NULL);
	return created;
}

/* Six faces, two triangles each; each corner its own colour. */
static int create_vertex_buffer(void)
{
	static const float corners[8][3] = {
		{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
		{-1, -1, 1},  {1, -1, 1},  {1, 1, 1},  {-1, 1, 1},
	};
	static const float colors[8][3] = {
		{0.1f, 0.1f, 0.1f}, {1, 0.2f, 0.2f}, {1, 1, 0.2f}, {0.2f, 1, 0.2f},
		{0.2f, 0.2f, 1},    {1, 0.2f, 1},    {1, 1, 1},    {0.2f, 1, 1},
	};
	static const int faces[6][4] = {
		{0, 1, 2, 3}, {5, 4, 7, 6}, {4, 0, 3, 7}, {1, 5, 6, 2}, {4, 5, 1, 0}, {3, 2, 6, 7},
	};
	static const int corner_order[6] = {0, 1, 2, 0, 2, 3};
	float vertices[36 * 6];
	VkBufferCreateInfo buffer_info = {
		.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.size = sizeof(vertices),
		.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
	};
	VkMemoryRequirements requirements;
	VkMemoryAllocateInfo allocate_info = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	void *mapped = NULL;
	int count = 0;

	for (int face = 0; face < 6; face++)
		for (int i = 0; i < 6; i++) {
			int corner = faces[face][corner_order[i]];
			memcpy(&vertices[count * 6], corners[corner], 3 * sizeof(float));
			memcpy(&vertices[count * 6 + 3], colors[corner], 3 * sizeof(float));
			count++;
		}

	if (!check(vkCreateBuffer(device, &buffer_info, NULL, &vertex_buffer), "vkCreateBuffer"))
		return 0;
	vkGetBufferMemoryRequirements(device, vertex_buffer, &requirements);
	allocate_info.allocationSize = requirements.size;
	allocate_info.memoryTypeIndex = memory_type(requirements.memoryTypeBits,
						    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
							    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	if (!check(vkAllocateMemory(device, &allocate_info, NULL, &vertex_memory), "vkAllocateMemory") ||
	    !check(vkMapMemory(device, vertex_memory, 0, sizeof(vertices), 0, &mapped), "vkMapMemory"))
		return 0;
	memcpy(mapped, vertices, sizeof(vertices));
	vkUnmapMemory(device, vertex_memory);
	return check(vkBindBufferMemory(device, vertex_buffer, vertex_memory, 0), "vkBindBufferMemory");
}

static int create_frame_objects(void)
{
	VkCommandPoolCreateInfo pool_info = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
		.queueFamilyIndex = queue_family,
	};
	VkCommandBufferAllocateInfo buffer_info = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
		.commandBufferCount = 1,
	};
	VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
	VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};

	if (!check(vkCreateCommandPool(device, &pool_info, NULL, &command_pool), "vkCreateCommandPool"))
		return 0;
	buffer_info.commandPool = command_pool;
	return check(vkAllocateCommandBuffers(device, &buffer_info, &command_buffer), "vkAllocateCommandBuffers") &&
	       check(vkCreateSemaphore(device, &semaphore_info, NULL, &image_acquired), "vkCreateSemaphore") &&
	       check(vkCreateSemaphore(device, &semaphore_info, NULL, &rendering_done), "vkCreateSemaphore") &&
	       check(vkCreateFence(device, &fence_info, NULL, &frame_done), "vkCreateFence");
}

/* --- The swapchain, made again when the window's size changes ------------- */

static void destroy_swapchain(void)
{
	for (uint32_t i = 0; i < chain.image_count; i++) {
		vkDestroyFramebuffer(device, chain.framebuffers[i], NULL);
		vkDestroyImageView(device, chain.views[i], NULL);
	}
	if (chain.depth_view)
		vkDestroyImageView(device, chain.depth_view, NULL);
	if (chain.depth_image)
		vkDestroyImage(device, chain.depth_image, NULL);
	if (chain.depth_memory)
		vkFreeMemory(device, chain.depth_memory, NULL);
	if (chain.swapchain)
		vkDestroySwapchainKHR(device, chain.swapchain, NULL);
	memset(&chain, 0, sizeof(chain));
}

static int create_depth_buffer(void)
{
	VkImageCreateInfo image_info = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_D32_SFLOAT,
		.extent = {chain.extent.width, chain.extent.height, 1},
		.mipLevels = 1,
		.arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
	};
	VkMemoryRequirements requirements;
	VkMemoryAllocateInfo allocate_info = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
	VkImageViewCreateInfo view_info = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_D32_SFLOAT,
		.subresourceRange = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1},
	};

	if (!check(vkCreateImage(device, &image_info, NULL, &chain.depth_image), "vkCreateImage"))
		return 0;
	vkGetImageMemoryRequirements(device, chain.depth_image, &requirements);
	allocate_info.allocationSize = requirements.size;
	allocate_info.memoryTypeIndex = memory_type(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (!check(vkAllocateMemory(device, &allocate_info, NULL, &chain.depth_memory), "vkAllocateMemory") ||
	    !check(vkBindImageMemory(device, chain.depth_image, chain.depth_memory, 0), "vkBindImageMemory"))
		return 0;
	view_info.image = chain.depth_image;
	return check(vkCreateImageView(device, &view_info, NULL, &chain.depth_view), "vkCreateImageView");
}

static int create_swapchain(struct fpos_window *window)
{
	VkSurfaceCapabilitiesKHR capabilities;
	VkSwapchainCreateInfoKHR info = {
		.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
		.surface = surface,
		.imageFormat = color_format,
		.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
		.imageArrayLayers = 1,
		.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
		.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
		.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
		.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
		.presentMode = VK_PRESENT_MODE_FIFO_KHR,
		.clipped = VK_TRUE,
	};

	if (!check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities),
		   "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))
		return 0;
	chain.extent = capabilities.currentExtent;
	if (chain.extent.width == UINT32_MAX) {
		chain.extent.width = window->width;
		chain.extent.height = window->height;
	}
	info.minImageCount = capabilities.minImageCount < 3 ? 3 : capabilities.minImageCount;
	info.imageExtent = chain.extent;
	if (!check(vkCreateSwapchainKHR(device, &info, NULL, &chain.swapchain), "vkCreateSwapchainKHR"))
		return 0;
	chain.image_count = MAXIMUM_IMAGES;
	if (!check(vkGetSwapchainImagesKHR(device, chain.swapchain, &chain.image_count, chain.images),
		   "vkGetSwapchainImagesKHR"))
		return 0;
	if (!create_depth_buffer())
		return 0;
	for (uint32_t i = 0; i < chain.image_count; i++) {
		VkImageViewCreateInfo view_info = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.image = chain.images[i],
			.viewType = VK_IMAGE_VIEW_TYPE_2D,
			.format = color_format,
			.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
		};
		VkImageView attachments[2];
		VkFramebufferCreateInfo framebuffer_info = {
			.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
			.renderPass = render_pass,
			.attachmentCount = 2,
			.pAttachments = attachments,
			.width = chain.extent.width,
			.height = chain.extent.height,
			.layers = 1,
		};
		if (!check(vkCreateImageView(device, &view_info, NULL, &chain.views[i]), "vkCreateImageView"))
			return 0;
		attachments[0] = chain.views[i];
		attachments[1] = chain.depth_view;
		if (!check(vkCreateFramebuffer(device, &framebuffer_info, NULL, &chain.framebuffers[i]),
			   "vkCreateFramebuffer"))
			return 0;
	}
	return 1;
}

static int recreate_swapchain(struct fpos_window *window)
{
	vkDeviceWaitIdle(device);
	destroy_swapchain();
	return create_swapchain(window);
}

/* --- Frames ------------------------------------------------------------------ */

/* Draws and presents one frame; 0 on an error, -1 when the swapchain no
   longer fits the window. */
static int draw_frame(float seconds)
{
	VkClearValue clear[2] = {
		{.color = {{CLEAR_RED, CLEAR_GREEN, CLEAR_BLUE, 1.0f}}},
		{.depthStencil = {1.0f, 0}},
	};
	VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	VkRenderPassBeginInfo pass = {
		.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
		.renderPass = render_pass,
		.renderArea = {{0, 0}, chain.extent},
		.clearValueCount = 2,
		.pClearValues = clear,
	};
	VkViewport viewport = {0, 0, (float)chain.extent.width, (float)chain.extent.height, 0.0f, 1.0f};
	VkRect2D scissor = {{0, 0}, chain.extent};
	VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
	VkSubmitInfo submit = {
		.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
		.waitSemaphoreCount = 1,
		.pWaitSemaphores = &image_acquired,
		.pWaitDstStageMask = &wait_stage,
		.commandBufferCount = 1,
		.pCommandBuffers = &command_buffer,
		.signalSemaphoreCount = 1,
		.pSignalSemaphores = &rendering_done,
	};
	VkPresentInfoKHR present = {
		.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
		.waitSemaphoreCount = 1,
		.pWaitSemaphores = &rendering_done,
		.swapchainCount = 1,
		.pSwapchains = &chain.swapchain,
	};
	VkDeviceSize offset = 0;
	float transform[16];
	uint32_t index = 0;
	VkResult result;

	vkWaitForFences(device, 1, &frame_done, VK_TRUE, UINT64_MAX);
	result = vkAcquireNextImageKHR(device, chain.swapchain, UINT64_MAX, image_acquired, VK_NULL_HANDLE, &index);
	if (result == VK_ERROR_OUT_OF_DATE_KHR)
		return -1;
	if (!check(result, "vkAcquireNextImageKHR"))
		return 0;
	vkResetFences(device, 1, &frame_done);

	cube_transform(transform, seconds, (float)chain.extent.width / (float)chain.extent.height);
	pass.framebuffer = chain.framebuffers[index];
	vkResetCommandBuffer(command_buffer, 0);
	vkBeginCommandBuffer(command_buffer, &begin);
	vkCmdBeginRenderPass(command_buffer, &pass, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
	vkCmdSetViewport(command_buffer, 0, 1, &viewport);
	vkCmdSetScissor(command_buffer, 0, 1, &scissor);
	vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffer, &offset);
	vkCmdPushConstants(command_buffer, pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(transform),
			   transform);
	vkCmdDraw(command_buffer, 36, 1, 0, 0);
	vkCmdEndRenderPass(command_buffer);
	vkEndCommandBuffer(command_buffer);
	if (!check(vkQueueSubmit(queue, 1, &submit, frame_done), "vkQueueSubmit"))
		return 0;

	present.pImageIndices = &index;
	result = vkQueuePresentKHR(queue, &present);
	if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR)
		return -1;
	return check(result, "vkQueuePresentKHR");
}

/* Whether the window shows the cube: enough pixels unlike the clear colour. */
static int window_shows_cube(struct fpos_window *window)
{
	const uint32_t background = 0xFF000000u | ((uint32_t)(CLEAR_RED * 255 + 0.5f) << 16) |
				    ((uint32_t)(CLEAR_GREEN * 255 + 0.5f) << 8) | (uint32_t)(CLEAR_BLUE * 255 + 0.5f);
	long pixels = (long)window->width * window->height, different = 0;
	for (long i = 0; i < pixels; i++)
		if ((window->pixels[i] | 0xFF000000u) != background)
			different++;
	printf("vkcube: %ld of %ld pixels show the cube\n", different, pixels);
	return different > pixels / 20 && different < pixels;
}

static int handle_events(struct fpos_display *display, struct fpos_window *window, int *resized)
{
	struct fpos_window_message message;
	while (fpos_display_next_event(display, &message)) {
		switch (message.kind) {
		case FPOS_EVENT_CLOSE_REQUESTED:
			return 0;
		case FPOS_EVENT_KEY:
			if (message.value && message.code == FPOS_KEY_ESCAPE)
				return 0;
			break;
		case FPOS_EVENT_RESIZED:
			fpos_window_set_surface(window, message.surface_width, message.surface_height);
			*resized = 1;
			break;
		case FPOS_EVENT_SCALE_CHANGED:
			if (message.window == window->number && window->scale) {
				int width = window->width * (int)message.code / (int)window->scale;
				int height = window->height * (int)message.code / (int)window->scale;
				window->scale = message.code;
				fpos_window_set_surface(window, width, height);
				*resized = 1;
			}
			break;
		default:
			break;
		}
	}
	return !display->broken;
}

int main(int argc, char **argv)
{
	struct fpos_display display;
	struct fpos_window window;
	long frame_limit = 0, frames = 0, frames_counted = 0;
	double start, last_report;
	int side, status = 0, resized = 0;

	if (argc == 3 && strcmp(argv[1], "-n") == 0)
		frame_limit = atol(argv[2]);
	if (fpos_display_connect(&display) != 0) {
		fprintf(stderr, "vkcube: no display server\n");
		return 1;
	}
	side = fpos_logical_to_pixels(WINDOW_SIDE, display.scale);
	if (fpos_window_create(&display, 460, 120, side, side, "Vulkan cube",
			       FPOS_WINDOW_FRAMED | FPOS_WINDOW_RESIZABLE, &window) != 0) {
		fprintf(stderr, "vkcube: cannot make a window\n");
		return 1;
	}
	fpos_window_show(&window, 1);

	if (!load_driver() || !create_instance_and_surface(&window) || !create_device() || !choose_format() ||
	    !create_render_pass() || !create_pipeline() || !create_vertex_buffer() || !create_frame_objects() ||
	    !create_swapchain(&window))
		return 1;

	start = last_report = seconds_now();
	while (handle_events(&display, &window, &resized)) {
		double now = seconds_now();
		int drawn;
		if (resized) {
			resized = 0;
			if (!recreate_swapchain(&window))
				return 1;
		}
		drawn = draw_frame((float)(now - start));
		if (drawn == 0)
			return 1;
		if (drawn < 0) {
			if (!recreate_swapchain(&window))
				return 1;
			continue;
		}
		frames++;
		frames_counted++;
		if (now - last_report >= 5.0 || (frame_limit && frames >= frame_limit)) {
			printf("vkcube: %ld frames in %.1f seconds = %.1f FPS\n", frames_counted, now - last_report,
			       frames_counted / (now - last_report > 0 ? now - last_report : 1));
			fflush(stdout);
			last_report = now;
			frames_counted = 0;
		}
		if (frame_limit && frames >= frame_limit) {
			vkDeviceWaitIdle(device);
			if (!window_shows_cube(&window))
				status = 1;
			break;
		}
	}

	vkDeviceWaitIdle(device);
	destroy_swapchain();
	vkDestroyFence(device, frame_done, NULL);
	vkDestroySemaphore(device, rendering_done, NULL);
	vkDestroySemaphore(device, image_acquired, NULL);
	vkDestroyCommandPool(device, command_pool, NULL);
	vkDestroyBuffer(device, vertex_buffer, NULL);
	vkFreeMemory(device, vertex_memory, NULL);
	vkDestroyPipeline(device, pipeline, NULL);
	vkDestroyPipelineLayout(device, pipeline_layout, NULL);
	vkDestroyRenderPass(device, render_pass, NULL);
	vkDestroyDevice(device, NULL);
	vkDestroySurfaceKHR(instance, surface, NULL);
	vkDestroyInstance(instance, NULL);
	fpos_window_destroy(&window);
	fpos_display_disconnect(&display);
	if (frame_limit)
		printf("vkcube: %s\n", status == 0 ? "cube presented" : "FAIL: the window does not show the cube");
	return status;
}
