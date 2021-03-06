#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent
  class Kube_nodeInventory_Input < Input
    Plugin.register_input("kubenodeinventory", self)

    @@ContainerNodeInventoryTag = "oms.containerinsights.ContainerNodeInventory"
    @@MDMKubeNodeInventoryTag = "mdm.kubenodeinventory"
    @@configMapMountPath = "/etc/config/settings/log-data-collection-settings"
    @@promConfigMountPath = "/etc/config/settings/prometheus-data-collection-settings"
    @@AzStackCloudFileName = "/etc/kubernetes/host/azurestackcloud.json"
    @@kubeperfTag = "oms.api.KubePerf"

    @@rsPromInterval = ENV["TELEMETRY_RS_PROM_INTERVAL"]
    @@rsPromFieldPassCount = ENV["TELEMETRY_RS_PROM_FIELDPASS_LENGTH"]
    @@rsPromFieldDropCount = ENV["TELEMETRY_RS_PROM_FIELDDROP_LENGTH"]
    @@rsPromK8sServiceCount = ENV["TELEMETRY_RS_PROM_K8S_SERVICES_LENGTH"]
    @@rsPromUrlCount = ENV["TELEMETRY_RS_PROM_URLS_LENGTH"]
    @@rsPromMonitorPods = ENV["TELEMETRY_RS_PROM_MONITOR_PODS"]
    @@rsPromMonitorPodsNamespaceLength = ENV["TELEMETRY_RS_PROM_MONITOR_PODS_NS_LENGTH"]
    @@collectAllKubeEvents = ENV["AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS"]

    def initialize
      super
      require "yaml"
      require "yajl/json_gem"
      require "yajl"
      require "time"

      require_relative "KubernetesApiClient"
      require_relative "ApplicationInsightsUtility"
      require_relative "oms_common"
      require_relative "omslog"
      @NODES_CHUNK_SIZE = "400"
      require_relative "constants"
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oms.containerinsights.KubeNodeInventory"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
      end
    end

    def enumerate
      begin
        nodeInventory = nil
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601

        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kube_nodes::enumerate : Getting nodes from Kube API @ #{Time.now.utc.iso8601}")
        resourceUri = KubernetesApiClient.getNodesResourceUri("nodes?limit=#{@NODES_CHUNK_SIZE}")
        continuationToken, nodeInventory = KubernetesApiClient.getResourcesAndContinuationToken(resourceUri)

        $log.info("in_kube_nodes::enumerate : Done getting nodes from Kube API @ #{Time.now.utc.iso8601}")
        if (!nodeInventory.nil? && !nodeInventory.empty? && nodeInventory.key?("items") && !nodeInventory["items"].nil? && !nodeInventory["items"].empty?)
          parse_and_emit_records(nodeInventory, batchTime)
        else
          $log.warn "in_kube_nodes::enumerate:Received empty nodeInventory"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          continuationToken, nodeInventory = KubernetesApiClient.getResourcesAndContinuationToken(resourceUri + "&continue=#{continuationToken}")
          if (!nodeInventory.nil? && !nodeInventory.empty? && nodeInventory.key?("items") && !nodeInventory["items"].nil? && !nodeInventory["items"].empty?)
            parse_and_emit_records(nodeInventory, batchTime)
          else
            $log.warn "in_kube_nodes::enumerate:Received empty nodeInventory"
          end
        end

        # Setting this to nil so that we dont hold memory until GC kicks in
        nodeInventory = nil
      rescue => errorStr
        $log.warn "in_kube_nodes::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end # end enumerate

    def parse_and_emit_records(nodeInventory, batchTime = Time.utc.iso8601)
      begin
        currentTime = Time.now
        emitTime = currentTime.to_f
        telemetrySent = false
        eventStream = MultiEventStream.new
        containerNodeInventoryEventStream = MultiEventStream.new
        insightsMetricsEventStream = MultiEventStream.new
        @@istestvar = ENV["ISTEST"]
        #get node inventory
        nodeInventory["items"].each do |items|
          record = {}
          # Sending records for ContainerNodeInventory
          containerNodeInventoryRecord = {}
          containerNodeInventoryRecord["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
          containerNodeInventoryRecord["Computer"] = items["metadata"]["name"]

          record["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
          record["Computer"] = items["metadata"]["name"]
          record["ClusterName"] = KubernetesApiClient.getClusterName
          record["ClusterId"] = KubernetesApiClient.getClusterId
          record["CreationTimeStamp"] = items["metadata"]["creationTimestamp"]
          record["Labels"] = [items["metadata"]["labels"]]
          record["Status"] = ""

          if !items["spec"]["providerID"].nil? && !items["spec"]["providerID"].empty?
            if File.file?(@@AzStackCloudFileName) # existence of this file indicates agent running on azstack
              record["KubernetesProviderID"] = "azurestack"
            else
              #Multicluster kusto query is filtering after splitting by ":" to the left, so do the same here
              #https://msazure.visualstudio.com/One/_git/AzureUX-Monitoring?path=%2Fsrc%2FMonitoringExtension%2FClient%2FInfraInsights%2FData%2FQueryTemplates%2FMultiClusterKustoQueryTemplate.ts&_a=contents&version=GBdev
              provider = items["spec"]["providerID"].split(":")[0]
              if !provider.nil? && !provider.empty?
                record["KubernetesProviderID"] = provider
              else
                record["KubernetesProviderID"] = items["spec"]["providerID"]
              end
            end
          else
            record["KubernetesProviderID"] = "onprem"
          end

          # Refer to https://kubernetes.io/docs/concepts/architecture/nodes/#condition for possible node conditions.
          # We check the status of each condition e.g. {"type": "OutOfDisk","status": "False"} . Based on this we
          # populate the KubeNodeInventory Status field. A possible value for this field could be "Ready OutofDisk"
          # implying that the node is ready for hosting pods, however its out of disk.

          if items["status"].key?("conditions") && !items["status"]["conditions"].empty?
            allNodeConditions = ""
            items["status"]["conditions"].each do |condition|
              if condition["status"] == "True"
                if !allNodeConditions.empty?
                  allNodeConditions = allNodeConditions + "," + condition["type"]
                else
                  allNodeConditions = condition["type"]
                end
              end
              #collect last transition to/from ready (no matter ready is true/false)
              if condition["type"] == "Ready" && !condition["lastTransitionTime"].nil?
                record["LastTransitionTimeReady"] = condition["lastTransitionTime"]
              end
            end
            if !allNodeConditions.empty?
              record["Status"] = allNodeConditions
            end
          end

          nodeInfo = items["status"]["nodeInfo"]
          record["KubeletVersion"] = nodeInfo["kubeletVersion"]
          record["KubeProxyVersion"] = nodeInfo["kubeProxyVersion"]
          containerNodeInventoryRecord["OperatingSystem"] = nodeInfo["osImage"]
          containerRuntimeVersion = nodeInfo["containerRuntimeVersion"]
          if containerRuntimeVersion.downcase.start_with?("docker://")
            containerNodeInventoryRecord["DockerVersion"] = containerRuntimeVersion.split("//")[1]
          else
            # using containerRuntimeVersion as DockerVersion as is for non docker runtimes
            containerNodeInventoryRecord["DockerVersion"] = containerRuntimeVersion
          end
          # ContainerNodeInventory data for docker version and operating system.
          containerNodeInventoryWrapper = {
            "DataType" => "CONTAINER_NODE_INVENTORY_BLOB",
            "IPName" => "ContainerInsights",
            "DataItems" => [containerNodeInventoryRecord.each { |k, v| containerNodeInventoryRecord[k] = v }],
          }
          containerNodeInventoryEventStream.add(emitTime, containerNodeInventoryWrapper) if containerNodeInventoryWrapper

          wrapper = {
            "DataType" => "KUBE_NODE_INVENTORY_BLOB",
            "IPName" => "ContainerInsights",
            "DataItems" => [record.each { |k, v| record[k] = v }],
          }
          eventStream.add(emitTime, wrapper) if wrapper
          # Adding telemetry to send node telemetry every 10 minutes
          timeDifference = (DateTime.now.to_time.to_i - @@nodeTelemetryTimeTracker).abs
          timeDifferenceInMinutes = timeDifference / 60
          if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
            properties = {}
            properties["Computer"] = record["Computer"]
            properties["KubeletVersion"] = record["KubeletVersion"]
            properties["OperatingSystem"] = nodeInfo["operatingSystem"]
            # DockerVersion field holds docker version if runtime is docker/moby else <runtime>://<version>
            if containerRuntimeVersion.downcase.start_with?("docker://")
              properties["DockerVersion"] = containerRuntimeVersion.split("//")[1]
            else
              properties["DockerVersion"] = containerRuntimeVersion
            end
            properties["KubernetesProviderID"] = record["KubernetesProviderID"]
            properties["KernelVersion"] = nodeInfo["kernelVersion"]
            properties["OSImage"] = nodeInfo["osImage"]

            capacityInfo = items["status"]["capacity"]
            ApplicationInsightsUtility.sendMetricTelemetry("NodeMemory", capacityInfo["memory"], properties)

            begin
              if (!capacityInfo["nvidia.com/gpu"].nil?) && (!capacityInfo["nvidia.com/gpu"].empty?)
                properties["nvigpus"] = capacityInfo["nvidia.com/gpu"]
              end

              if (!capacityInfo["amd.com/gpu"].nil?) && (!capacityInfo["amd.com/gpu"].empty?)
                properties["amdgpus"] = capacityInfo["amd.com/gpu"]
              end
            rescue => errorStr
              $log.warn "Failed in getting GPU telemetry in_kube_nodes : #{errorStr}"
              $log.debug_backtrace(errorStr.backtrace)
              ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
            end

            # Telemetry for data collection config for replicaset
            if (File.file?(@@configMapMountPath))
              properties["collectAllKubeEvents"] = @@collectAllKubeEvents
            end

            #telemetry about prometheus metric collections settings for replicaset
            if (File.file?(@@promConfigMountPath))
              properties["rsPromInt"] = @@rsPromInterval
              properties["rsPromFPC"] = @@rsPromFieldPassCount
              properties["rsPromFDC"] = @@rsPromFieldDropCount
              properties["rsPromServ"] = @@rsPromK8sServiceCount
              properties["rsPromUrl"] = @@rsPromUrlCount
              properties["rsPromMonPods"] = @@rsPromMonitorPods
              properties["rsPromMonPodsNs"] = @@rsPromMonitorPodsNamespaceLength
            end
            ApplicationInsightsUtility.sendMetricTelemetry("NodeCoreCapacity", capacityInfo["cpu"], properties)
            telemetrySent = true
          end
        end
        router.emit_stream(@tag, eventStream) if eventStream
        router.emit_stream(@@MDMKubeNodeInventoryTag, eventStream) if eventStream
        router.emit_stream(@@ContainerNodeInventoryTag, containerNodeInventoryEventStream) if containerNodeInventoryEventStream
        if telemetrySent == true
          @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
        end

        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && eventStream.count > 0)
          $log.info("kubeNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
        #:optimize:kubeperf merge
        begin
          #if(!nodeInventory.empty?)
          nodeMetricDataItems = []
          #allocatable metrics @ node level
          nodeMetricDataItems.concat(KubernetesApiClient.parseNodeLimits(nodeInventory, "allocatable", "cpu", "cpuAllocatableNanoCores", batchTime))
          nodeMetricDataItems.concat(KubernetesApiClient.parseNodeLimits(nodeInventory, "allocatable", "memory", "memoryAllocatableBytes", batchTime))
          #capacity metrics @ node level
          nodeMetricDataItems.concat(KubernetesApiClient.parseNodeLimits(nodeInventory, "capacity", "cpu", "cpuCapacityNanoCores", batchTime))
          nodeMetricDataItems.concat(KubernetesApiClient.parseNodeLimits(nodeInventory, "capacity", "memory", "memoryCapacityBytes", batchTime))

          kubePerfEventStream = MultiEventStream.new

          nodeMetricDataItems.each do |record|
            record["DataType"] = "LINUX_PERF_BLOB"
            record["IPName"] = "LogManagement"
            kubePerfEventStream.add(emitTime, record) if record
          end
          #end
          router.emit_stream(@@kubeperfTag, kubePerfEventStream) if kubePerfEventStream

          #start GPU InsightsMetrics items
          begin
            nodeGPUInsightsMetricsDataItems = []
            nodeGPUInsightsMetricsDataItems.concat(KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(nodeInventory, "allocatable", "nvidia.com/gpu", "nodeGpuAllocatable", batchTime))
            nodeGPUInsightsMetricsDataItems.concat(KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(nodeInventory, "capacity", "nvidia.com/gpu", "nodeGpuCapacity", batchTime))

            nodeGPUInsightsMetricsDataItems.concat(KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(nodeInventory, "allocatable", "amd.com/gpu", "nodeGpuAllocatable", batchTime))
            nodeGPUInsightsMetricsDataItems.concat(KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(nodeInventory, "capacity", "amd.com/gpu", "nodeGpuCapacity", batchTime))

            nodeGPUInsightsMetricsDataItems.each do |insightsMetricsRecord|
              wrapper = {
                "DataType" => "INSIGHTS_METRICS_BLOB",
                "IPName" => "ContainerInsights",
                "DataItems" => [insightsMetricsRecord.each { |k, v| insightsMetricsRecord[k] = v }],
              }
              insightsMetricsEventStream.add(emitTime, wrapper) if wrapper
            end

            router.emit_stream(Constants::INSIGHTSMETRICS_FLUENT_TAG, insightsMetricsEventStream) if insightsMetricsEventStream
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && insightsMetricsEventStream.count > 0)
              $log.info("kubeNodeInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          rescue => errorStr
            $log.warn "Failed when processing GPU metrics in_kube_nodes : #{errorStr}"
            $log.debug_backtrace(errorStr.backtrace)
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
          #end GPU InsightsMetrics items
        rescue => errorStr
          $log.warn "Failed in enumerate for KubePerf from in_kube_nodes : #{errorStr}"
          $log.debug_backtrace(errorStr.backtrace)
          ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
        end
        #:optimize:end kubeperf merge

      rescue => errorStr
        $log.warn "Failed to retrieve node inventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      $log.info "in_kube_nodes::parse_and_emit_records:End #{Time.now.utc.iso8601}"
    end

    def run_periodic
      @mutex.lock
      done = @finished
      @nextTimeToRun = Time.now
      @waitTimeout = @run_interval
      until done
        @nextTimeToRun = @nextTimeToRun + @run_interval
        @now = Time.now
        if @nextTimeToRun <= @now
          @waitTimeout = 1
          @nextTimeToRun = @now
        else
          @waitTimeout = @nextTimeToRun - @now
        end
        @condition.wait(@mutex, @waitTimeout)
        done = @finished
        @mutex.unlock
        if !done
          begin
            $log.info("in_kube_nodes::run_periodic.enumerate.start #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_nodes::run_periodic.enumerate.end #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_nodes::run_periodic: enumerate Failed to retrieve node inventory: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # Kube_Node_Input
end # module
