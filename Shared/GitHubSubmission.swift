import Foundation

enum GitHubSubmission {
    static let communityContributionURL = URL(
        string: "https://github.com/AreaSong/location-spoofer/discussions/new?category=show-and-tell"
    )!
    static let usageHelpURL = URL(
        string: "https://github.com/AreaSong/location-spoofer/discussions/categories/q-a"
    )!
    static let featureRequestURL = URL(
        string: "https://github.com/AreaSong/location-spoofer/discussions/categories/ideas"
    )!
    static let bugReportURL = URL(
        string: "https://github.com/AreaSong/location-spoofer/issues/new?template=bug-report.yml"
    )!

    static func communityContributionTemplate(
        for client: ThirdPartyProxyClient,
        systemVersion: String
    ) -> String {
        """
        ## 第三方客户端
        \(client.name)

        ## 第三方客户端版本
        请填写当前使用的第三方客户端版本。

        ## iOS 版本
        iOS \(systemVersion)

        ## 配置步骤
        请描述模块导入、证书或解密设置、代理连接和最终验证过程。

        ## 截图与补充说明
        请附上脱敏原图，并说明每张图片对应的步骤。

        ## README 收录署名
        - [ ] 匿名收录，不在 README 展示投稿账号
        """
    }
}
