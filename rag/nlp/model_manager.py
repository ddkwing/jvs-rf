"""
模型管理器 - 负责管理rerank模型的生命周期
"""
import os
import atexit
import threading
from typing import Optional, Dict, Any, List
import logging as logger
import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification
import time
class RerankModel:
    def __init__(self, model_path: str, device_id: int = 0):
        self.model_path = model_path
        self.device = torch.device(f"cuda:{device_id}" if torch.cuda.is_available() else "cpu")
        logger.info(f"Using device: {self.device}")

        # 加载模型和分词器
        self.load_model()

    def load_model(self):
        """加载模型和分词器"""
        try:
            logger.info("Loading tokenizer...")
            self.tokenizer = AutoTokenizer.from_pretrained(self.model_path)

            logger.info("Loading model...")
            self.model = AutoModelForSequenceClassification.from_pretrained(
                self.model_path,
                torch_dtype=torch.float16,  # 使用半精度加速推理
                device_map="auto"
            ).to(self.device)

            # 设置为评估模式
            self.model.eval()

            # 预热模型
            self.warmup()

            logger.info("Model loaded successfully!")

        except Exception as e:
            logger.error(f"Error loading model: {e}")
            raise

    def warmup(self):
        """预热模型，提高首次推理性能"""
        logger.info("Warming up model...")
        dummy_query = "test query"
        dummy_passage = "test passage"

        with torch.no_grad():
            inputs = self.tokenizer(
                [dummy_query], [dummy_passage],
                padding=True,
                truncation=True,
                return_tensors='pt',
                max_length=512
            ).to(self.device)

            _ = self.model(**inputs)

        logger.info("Model warmup completed!")

    def rerank(self, query: str, passages: List[str], top_k: Optional[int] = None) -> Dict[str, Any]:
        """
        对查询和文档进行重排序

        Args:
            query: 查询文本
            passages: 候选文档列表
            top_k: 返回top-k个结果，如果为None则返回所有结果

        Returns:
            包含分数和排序结果的字典
        """
        if not passages:
            return {"scores": [], "ranked_passages": []}

        start_time = time.time()

        try:
            # 批量处理以提高效率
            batch_size = 32  # 根据GPU内存调整
            all_scores = []

            for i in range(0, len(passages), batch_size):
                batch_passages = passages[i:i + batch_size]
                batch_queries = [query] * len(batch_passages)

                # 分词
                inputs = self.tokenizer(
                    batch_queries,
                    batch_passages,
                    padding=True,
                    truncation=True,
                    return_tensors='pt',
                    max_length=512
                ).to(self.device)

                # 推理
                with torch.no_grad():
                    outputs = self.model(**inputs)
                    scores = outputs.logits.squeeze(-1).float()
                    all_scores.extend(scores.cpu().numpy().tolist())

            # 创建结果列表
            passage_scores = list(zip(passages, all_scores, range(len(passages))))

            # 按分数排序
            passage_scores.sort(key=lambda x: x[1], reverse=True)

            # 应用top_k限制
            if top_k:
                passage_scores = passage_scores[:top_k]

            # 构造返回结果
            scores = [score for _, score, _ in passage_scores]
            ranked_passages = [
                {
                    "passage": passage,
                    "score": score,
                    "original_index": orig_idx
                }
                for passage, score, orig_idx in passage_scores
            ]

            inference_time = time.time() - start_time
            logger.info(f"Rerank completed in {inference_time:.3f}s for {len(passages)} passages")

            return {
                "scores": scores,
                "ranked_passages": ranked_passages,
                "inference_time": inference_time
            }

        except Exception as e:
            logger.error(f"Error during reranking: {e}")
            return None

            
class ModelManager:
    """
    模型管理器，负责模型的加载、管理和清理
    采用单例模式确保全局唯一
    """
    _instance: Optional['ModelManager'] = None
    _lock = threading.Lock()
    
    def __new__(cls) -> 'ModelManager':
        """单例模式实现"""
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        """初始化模型管理器"""
        if hasattr(self, '_initialized'):
            return
            
        self._initialized = True
        self.rerank_model: Optional[RerankModel] = None
        self._model_lock = threading.RLock()
        self._is_loading = False
        
        # 注册退出清理函数
        atexit.register(self.cleanup)
        
    def initialize_models(self) -> None:
        """
        初始化所有模型
        在Flask应用启动时调用
        """
        with self._model_lock:
            if self._is_loading:
                logger.warning("Models are already being loaded, skipping...")
                return
                
            if self.rerank_model is not None:
                logger.warning("Models are already loaded, skipping...")
                return
                
            self._is_loading = True
            
        try:
            logger.info("开始初始化rerank模型...")
            
            # 从环境变量获取模型路径
            model_path = os.getenv(
                "MODEL_PATH", 
                "/ragflow/models/bge-reranker-v2-m3"
            )
            
            # 获取设备ID
            device_id = int(os.getenv("DEVICE_ID", "0"))
            
            # 加载rerank模型
            self.rerank_model = RerankModel(model_path, device_id)
            
            logger.info("rerank模型初始化完成!")
            
        except Exception as e:
            logger.error(f"模型初始化失败: {e}")
            # 清理部分加载的资源
            self._cleanup_models()
            raise
        finally:
            self._is_loading = False
    
    def get_rerank_model(self) -> Optional[RerankModel]:
        """
        获取rerank模型实例
        
        Returns:
            RerankModel实例，如果未初始化则返回None
        """
        with self._model_lock:
            if self.rerank_model is None:
                logger.warning("Rerank模型尚未初始化")
            return self.rerank_model
    
    def is_ready(self) -> bool:
        """
        检查模型是否准备就绪
        
        Returns:
            bool: 所有模型是否已加载完成
        """
        with self._model_lock:
            return (
                self.rerank_model is not None and 
                not self._is_loading
            )
    
    def get_model_status(self) -> Dict[str, Any]:
        """
        获取模型状态信息
        
        Returns:
            包含模型状态的字典
        """
        with self._model_lock:
            return {
                "rerank_model_loaded": self.rerank_model is not None,
                "is_loading": self._is_loading,
                "is_ready": self.is_ready()
            }
    
    def _cleanup_models(self) -> None:
        """清理模型资源（内部方法）"""
        try:
            if self.rerank_model is not None:
                # 如果模型有特定的清理方法，在这里调用
                # 对于PyTorch模型，通常不需要显式清理
                logger.info("清理rerank模型资源...")
                self.rerank_model = None
                
        except Exception as e:
            logger.error(f"清理模型资源时出错: {e}")
    
    def cleanup(self) -> None:
        """
        清理所有资源
        在应用关闭时调用
        """
        logger.info("开始清理模型管理器资源...")
        with self._model_lock:
            self._cleanup_models()
        logger.info("模型管理器资源清理完成")
    
    def __del__(self):
        """
        析构函数，确保资源被清理
        """
        try:
            self.cleanup()
        except Exception:
            # 在析构函数中不抛出异常
            pass
    
    def reload_models(self) -> None:
        """
        重新加载模型
        用于模型更新或错误恢复
        """
        logger.info("开始重新加载模型...")
        with self._model_lock:
            # 清理现有模型
            self._cleanup_models()
            # 重新初始化
            self._is_loading = False
            
        # 重新加载
        self.initialize_models()
        logger.info("模型重新加载完成")


# 全局模型管理器实例
model_manager = ModelManager()


def get_model_manager() -> ModelManager:
    """
    获取全局模型管理器实例
    
    Returns:
        ModelManager实例
    """
    return model_manager


def get_rerank_model() -> Optional[RerankModel]:
    """
    便捷函数：获取rerank模型实例
    
    Returns:
        RerankModel实例或None
    """
    return model_manager.get_rerank_model()
