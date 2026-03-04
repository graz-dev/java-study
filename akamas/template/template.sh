#!/bin/bash
bash /work/code/java-study/akamas/scripts/patch_petclinic.sh \
  --cpu-request ${petclinic_container.cpu_request} \
  --cpu-limit ${petclinic_container.cpu_limit} \
  --memory-request ${petclinic_container.memory_request} \
  --memory-limit ${petclinic_container.memory_limit} \
  --jvm-opts "${petclinic_jvm.*}" \
  --hpa-cpu-target ${petclinic_hpa.targetCPUUtilizationPercentage}
