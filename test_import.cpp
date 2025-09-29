int main() { 
  ProjectManager pm; 
  QJsonObject req; 
  req["file_path"] = "/Users/joe/Downloads/Create_a_video_202506121402_4t4jp.mp4";
  QJsonObject response = pm.importMedia("test-project", req);
  qDebug() << "Response:" << response;
  return 0; 
}
