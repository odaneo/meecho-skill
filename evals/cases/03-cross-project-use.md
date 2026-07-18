# Reuse one profile across projects

## User request

`$meecho:meecho` 依次在 alpha、beta、gamma 三个无关项目各写一段 80 字的雨天开头，复用同一个全局档案；只在聊天中给每段正文。

## Accessible files

case-03 的 alpha、beta、gamma 测试项目、允许的高中合成语料，以及 `meecho-eval` 自己的已建档 home。

## Forbidden state

开发者真实主目录、Plugin 缓存、封存作品和其他 case 的结果。

## Observable assertions

三项目读取同一全局档案；项目零写入；每次只有一份聊天正文，不创建 link、session 或局部档案。
