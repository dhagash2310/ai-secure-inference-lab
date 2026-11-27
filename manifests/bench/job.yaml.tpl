apiVersion: batch/v1
kind: Job
metadata:
  name: bench-@NAME@
  namespace: llm
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      enableServiceLinks: false
      containers:
        - name: bench
          image: guard-proxy:local   # already loaded on the nodes; has Python 3.12
          imagePullPolicy: IfNotPresent
          command: ["python", "/bench/prefix_bench.py", "--url", "@URL@", "--requests", "@REQS@", "--concurrency", "@CONC@", "--shared-prefix", "--groups", "@GROUPS@", "--prefix-rules", "@RULES@", "--salt", "@SALT@"]
          volumeMounts:
            - { name: script, mountPath: /bench }
      volumes:
        - name: script
          configMap: { name: bench-script }
