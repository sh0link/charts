写一个helm chart，用来部署ethereum节点，需求如下
1. 可以通过 ethereum-genesis-generator 生成一个全新的devnet，也可以创建任意多个非validator节点，加入一个已有的网络，比如mainnet或者 sepolia testnet, 通过values里的mode字段来控制
2. 支持每个节点配置任意 cl / el client类型，reth geth lighthouse prysm
3. 支持部署 dora-explorer， pgsql，blockscout，spamoor，等相关服务，使用debugger镜像的内置nginx启动一个genesis服务，用于提供genesis下载
4. 使用init容器来控制启动依赖，比如检测genesis生成了，再启动节点，el启动了，再启动cl
5. devnet模式，可以指定validator数量和非validator数量
6. 支持自动生成 ingress及其host，host命名规则参考已有项目 mantle-stack
7. 部分代码逻辑可以参考项目 @/Users/user/Workspaces/mantlenetworkio/mantle-config/cicd/mantle-stacks
8. 提供几个不同mode的example value.yaml和 helmrelease例子，对应的提供skills
9. 使用helm的Capabilities来检测是否支持 vmservicescrape CRD，是则部署
10. 本地通过k3d cluster 来部署测试 @lib/k3d-local0.conf
