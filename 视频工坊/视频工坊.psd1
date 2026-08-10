@{
	RootModule = '视频工坊.psm1'
	ModuleVersion = '1.1.0'
	GUID = '00279415-4bd7-49fe-aaf4-721625314781'
	Author = '埃博拉酱'
	CompanyName = '一致行动党'
	Copyright = '(c) 2026 埃博拉酱. MIT License.'
	Description = '视频工坊是面向本地视频处理的 PowerShell 工具模块，封装 ffmpeg、ffprobe 和 mkvmerge，提供烧录字幕、DV转HDR10、超级合并、设置ffmpeg路径、压缩到指定大小五个命令。烧录字幕会选取第一个视频轨和指定字幕轨，将文本字幕或常见位图字幕硬烧到画面，视频转 HEVC，音频和其它轨道尽量直接复制。DV转HDR10 使用带 libplacebo 滤镜的 ffmpeg 将 Dolby Vision 片源处理为 BT.2020、PQ、TV range 的 HDR10 HEVC 输出，支持质量参数和短样本测试。超级合并按列表文件或剪贴板顺序合并多个片段；同构轨道优先走 mkvmerge 精剪与 ffmpeg concat 的无损快速路径，异构片段按视频、音频、字幕兼容性选择 copy 或最小化重编码，编码格式允许动态分辨率时尽量保留原始尺寸，必要时才统一分辨率、补静音或补空字幕。压缩到指定大小用二次编码把视频轨重编码到指定文件大小，视频统一 HEVC，优先 NVIDIA NVENC，其余轨道原样保留。适合本地片段整理、字幕硬烧、Dolby Vision 兼容转换、合集封装和定量化压缩。依赖 ffmpeg/ffprobe，超级合并还需要 mkvmerge；缺少依赖时相关命令会尝试通过辅助安装脚本补齐。'
	PowerShellVersion = '5.1'

	FunctionsToExport = @('烧录字幕', 'DV转HDR10', '超级合并', '设置ffmpeg路径', '压缩到指定大小')

	PrivateData = @{
		PSData = @{
			Tags = @('ffmpeg', '字幕', '杜比视界', 'HDR10', 'HEVC', '视频合并', '压缩', '二次编码')
			LicenseUri = 'https://opensource.org/licenses/MIT'
			ProjectUri = 'https://github.com/Ebola-Chan-bot/Video-Workshop'
			ReleaseNotes = @'
新增 压缩到指定大小 公开命令，采用二次编码把视频轨重编码到指定文件大小：视频统一 HEVC，优先 NVIDIA NVENC、无 GPU 时回退 libx265，音频/字幕/附件等其它轨道全部原样复制，输出固定 MKV
'@
		}
	}
}


