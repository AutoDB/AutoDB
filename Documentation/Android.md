# Linux / Android / Windows 

Cross-platform support outside Apple platforms is a goal, not current release-ready functionality. The long-term direction is to avoid hard dependencies on ObjC-only system layers and keep the core database layer portable.

Current reality:

- The Swift package currently targets Apple platforms first.
- macOS and iOS are the platforms with regular test coverage today.
- Linux / Android / Windows support is still work in progress and should be treated as exploratory.
