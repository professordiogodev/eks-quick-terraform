# Turn EKS on and off super quickly with this repo!

You just need a working AWS account (with your AWS CLI already set up).

1. Clone the repo:

```bash
git clone https://github.com/professordiogodev/eks-quick-terraform
cd eks-quick-terraform
chmod +x up.sh down.sh
```

2. Turn on the cluster (has 2 t3.medium machines currently):
```
./up.sh
```

3. When you're done, turn it off!
```
./down.sh
```
